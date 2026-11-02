package migration_test

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// This disposable protocol fixture stores opaque native state/lock bytes. It
// exercises the real pinned S3 backend and migration CLI, not a modeled state
// manager. Real R2 behavior and credential scoping remain a separate live gate.
type objectStore struct {
	mu             sync.Mutex
	objects        map[string][]byte
	stateWrites    [][]byte
	denyStateRead  bool
	denyList       bool
	incompleteList bool
	echoAuth       bool
	injectOnUnlock []byte
}

func (s *objectStore) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r.Method == http.MethodGet && r.URL.Query().Get("list-type") == "2" {
		if s.denyList || (s.incompleteList && r.URL.Query().Get("continuation-token") != "") {
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusForbidden)
			_, _ = io.WriteString(w, "<Error><Code>AccessDenied</Code><RequestEcho>SYNTHETIC_FIXTURE_SESSION</RequestEcho></Error>")
			return
		}
		type entry struct {
			Key string `xml:"Key"`
		}
		result := struct {
			XMLName               xml.Name `xml:"ListBucketResult"`
			Name                  string   `xml:"Name"`
			Prefix                string   `xml:"Prefix"`
			IsTruncated           bool     `xml:"IsTruncated"`
			NextContinuationToken string   `xml:"NextContinuationToken,omitempty"`
			Contents              []entry  `xml:"Contents"`
			RequestEcho           string   `xml:"RequestEcho,omitempty"`
		}{}
		prefix := r.URL.Query().Get("prefix")
		result.Name = "state-fixture"
		result.Prefix = prefix
		if s.echoAuth {
			result.RequestEcho = "SYNTHETIC_FIXTURE_SESSION"
		}
		if s.incompleteList {
			result.IsTruncated = true
			result.NextContinuationToken = "unavailable"
		}
		for key := range s.objects {
			if strings.HasPrefix(key, prefix) {
				result.Contents = append(result.Contents, entry{key})
			}
		}
		w.Header().Set("Content-Type", "application/xml")
		if err := xml.NewEncoder(w).Encode(result); err != nil {
			panic(err)
		}
		return
	}
	key := strings.TrimPrefix(r.URL.Path, "/state-fixture/")
	value, exists := s.objects[key]
	switch r.Method {
	case http.MethodGet, http.MethodHead:
		if s.denyStateRead && !strings.HasSuffix(key, ".tflock") {
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusForbidden)
			_, _ = io.WriteString(w, "<Error><Code>AccessDenied</Code></Error>")
			return
		}
		if !exists {
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, "<Error><Code>NoSuchKey</Code></Error>")
			return
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(value)))
		if r.Method == http.MethodGet {
			_, _ = w.Write(value)
		}
	case http.MethodPut:
		if exists && r.Header.Get("If-None-Match") == "*" {
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusPreconditionFailed)
			_, _ = io.WriteString(w, "<Error><Code>PreconditionFailed</Code></Error>")
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err != nil {
			http.Error(w, "read failed", http.StatusBadRequest)
			return
		}
		s.objects[key] = append([]byte(nil), body...)
		if !strings.HasSuffix(key, ".tflock") {
			s.stateWrites = append(s.stateWrites, append([]byte(nil), body...))
		}
		w.Header().Set("ETag", `"fixture"`)
		w.WriteHeader(http.StatusOK)
	case http.MethodDelete:
		delete(s.objects, key)
		if strings.HasSuffix(key, ".tflock") && s.injectOnUnlock != nil {
			// A second writer publishes a native snapshot after the seed plan
			// releases its lock, before the saved plan can be applied.
			s.objects["proof/state.tfstate"] = append([]byte(nil), s.injectOnUnlock...)
			s.injectOnUnlock = nil
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "unsupported", http.StatusBadRequest)
	}
}

func TestNativeS3MigrationPreservesLineage(t *testing.T) {
	cache := t.TempDir()
	for _, scenario := range []string{"absent", "initialized-empty", "occupied-default", "occupied-named", "competing-writer", "read-denied", "list-denied", "list-truncated", "list-echo"} {
		t.Run(scenario, func(t *testing.T) { testNativeMigration(t, scenario, cache) })
	}
}

func testNativeMigration(t *testing.T, scenario, cache string) {
	tofu, err := exec.LookPath("tofu")
	if err != nil {
		t.Fatal(err)
	}
	repo, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	store := &objectStore{objects: make(map[string][]byte)}
	server := httptest.NewServer(store)
	t.Cleanup(server.Close)
	work := t.TempDir()
	module := filepath.Join(work, "source")
	logs := filepath.Join(work, "evidence")
	for _, dir := range []string{module, logs} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	env := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + work, "TF_IN_AUTOMATION=1", "CHECKPOINT_DISABLE=1", "AWS_EC2_METADATA_DISABLED=true", "AWS_ACCESS_KEY_ID=" + strings.Repeat("a", 32), "AWS_SECRET_ACCESS_KEY=" + strings.Repeat("b", 64), "AWS_SESSION_TOKEN=SYNTHETIC_FIXTURE_SESSION"}
	env = append(env, "GOCACHE="+cache)
	run := func(name string, args ...string) []byte {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, name, args...)
		cmd.Env = env
		output, err := cmd.CombinedOutput()
		if err != nil {
			for _, name := range []string{"destination-state.json", "destination-state-error.log", "seed-plan.log", "seed-show-error.log", "seed-apply.log"} {
				if diagnostic, readErr := os.ReadFile(filepath.Join(logs, name)); readErr == nil {
					t.Logf("%s: %s", name, diagnostic)
				}
			}
			t.Fatalf("native command failed: %v\n%s", err, output)
		}
		return output
	}
	write := func(path, value string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(module, "main.tf"), "terraform {\n required_version = \"= 1.12.6\"\n backend \"s3\" {}\n}\noutput \"proof\" { value = \"native-s3-lineage\" }\n")
	write(filepath.Join(module, "backend_override.tf"), "terraform {\n backend \"local\" {}\n}\n")
	run(tofu, "-chdir="+module, "init", "-input=false", "-no-color")
	run(tofu, "-chdir="+module, "apply", "-auto-approve", "-input=false", "-no-color")
	before := run(tofu, "-chdir="+module, "state", "pull")
	sourceFile, err := os.ReadFile(filepath.Join(module, "terraform.tfstate"))
	if err != nil {
		t.Fatal(err)
	}
	switch scenario {
	case "initialized-empty":
		empty := filepath.Join(work, "empty")
		if err := os.Mkdir(empty, 0700); err != nil {
			t.Fatal(err)
		}
		write(filepath.Join(empty, "main.tf"), "terraform { required_version = \"= 1.12.6\" }\n")
		run(tofu, "-chdir="+empty, "init", "-input=false", "-no-color")
		run(tofu, "-chdir="+empty, "apply", "-auto-approve", "-input=false", "-no-color")
		store.objects["proof/state.tfstate"] = run(tofu, "-chdir="+empty, "state", "pull")
	case "occupied-default":
		store.objects["proof/state.tfstate"] = append([]byte(nil), before...)
	case "occupied-named":
		store.objects["proof/workspaces/retained/proof/state.tfstate"] = append([]byte(nil), before...)
	case "competing-writer":
		store.injectOnUnlock = append([]byte(nil), before...)
	case "read-denied":
		store.denyStateRead = true
	case "list-denied":
		store.denyList = true
	case "list-truncated":
		store.incompleteList = true
	case "list-echo":
		store.echoAuth = true
	}
	if err := os.Remove(filepath.Join(module, "backend_override.tf")); err != nil {
		t.Fatal(err)
	}
	backend := filepath.Join(work, "backend.hcl")
	write(backend, fmt.Sprintf("bucket=\"state-fixture\"\nkey=\"proof/state.tfstate\"\nworkspace_key_prefix=\"proof/workspaces\"\nregion=\"auto\"\nendpoints={s3=%q}\nuse_path_style=true\nskip_credentials_validation=true\nskip_region_validation=true\nskip_requesting_account_id=true\nskip_metadata_api_check=true\nskip_s3_checksum=true\nuse_lockfile=true\n", server.URL))
	if scenario == "occupied-default" || scenario == "occupied-named" || scenario == "competing-writer" || scenario == "read-denied" || scenario == "list-denied" || scenario == "list-truncated" || scenario == "list-echo" {
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "bash", filepath.Join(repo, "scripts/migrate-native-backend.sh"), module, backend, logs)
		cmd.Env = env
		output, err := cmd.CombinedOutput()
		wantStage := map[string]string{
			"occupied-default": "destination-state",
			"occupied-named":   "listing-validation",
			"competing-writer": "empty-initialize",
			"read-denied":      "destination-initialize", // The pinned probe init refreshes state first.
			"list-denied":      "destination-listing",
			"list-truncated":   "listing-validation",
			"list-echo":        "listing-confidentiality",
		}[scenario]
		exit, ok := err.(*exec.ExitError)
		if !ok || exit.ExitCode() != 2 || !bytes.Contains(output, []byte("NATIVE_STATE_MIGRATION=UNVERIFIED stage="+wantStage+"\n")) {
			t.Fatalf("unsafe destination was not refused: %v\n%s", err, output)
		}
		unchanged, err := os.ReadFile(filepath.Join(module, "terraform.tfstate"))
		if err != nil || !bytes.Equal(sourceFile, unchanged) {
			t.Fatal("refused migration changed local source")
		}
		store.mu.Lock()
		defer store.mu.Unlock()
		if len(store.stateWrites) != 0 {
			t.Fatal("refused migration wrote remote state")
		}
		if scenario == "competing-writer" {
			failure, readErr := os.ReadFile(filepath.Join(logs, "seed-apply.log"))
			if readErr != nil || !bytes.Contains(failure, []byte("Error:")) || !bytes.Contains(failure, []byte("Saved plan")) {
				t.Fatal("competing writer was not refused by the native saved-plan guard")
			}
		}
		if scenario == "list-denied" || scenario == "list-echo" {
			if raw, readErr := os.ReadFile(filepath.Join(logs, "destination-list.xml")); readErr == nil && bytes.Contains(raw, []byte("SYNTHETIC_FIXTURE_SESSION")) {
				t.Fatal("failed listing retained an authentication echo in evidence")
			}
		}
		key := "proof/state.tfstate"
		if scenario == "occupied-named" {
			key = "proof/workspaces/retained/proof/state.tfstate"
		}
		if scenario != "read-denied" && scenario != "list-denied" && scenario != "list-truncated" && scenario != "list-echo" && !bytes.Equal(store.objects[key], before) {
			t.Fatal("refused migration changed occupied state")
		}
		return
	}
	run("bash", filepath.Join(repo, "scripts/migrate-native-backend.sh"), module, backend, logs)
	after := run(tofu, "-chdir="+module, "state", "pull")
	var source, target map[string]any
	if err := json.Unmarshal(before, &source); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(after, &target); err != nil {
		t.Fatal(err)
	}
	if source["lineage"] != target["lineage"] {
		t.Fatal("native S3 migration changed lineage")
	}
	if target["serial"].(float64) < source["serial"].(float64) {
		t.Fatal("native S3 migration decreased serial")
	}
	delete(source, "serial")
	delete(target, "serial")
	want, _ := json.Marshal(source)
	got, _ := json.Marshal(target)
	if !bytes.Equal(want, got) {
		t.Fatal("native S3 migration changed logical state")
	}
	if scenario == "absent" {
		store.mu.Lock()
		defer store.mu.Unlock()
		if len(store.stateWrites) < 2 {
			t.Fatal("native empty snapshot was not initialized before copy")
		}
		var seed struct {
			Resources []json.RawMessage          `json:"resources"`
			Outputs   map[string]json.RawMessage `json:"outputs"`
		}
		if err := json.Unmarshal(store.stateWrites[0], &seed); err != nil || len(seed.Resources) != 0 || len(seed.Outputs) != 0 {
			t.Fatal("initialization wrote non-empty state")
		}
	}
}
