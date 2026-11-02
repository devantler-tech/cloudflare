package main

import (
	"strings"
	"testing"
)

func TestWorkspaceListingRefusesIncompleteOrAmbiguousEvidence(t *testing.T) {
	valid := `<ListBucketResult><Name>state-fixture</Name><Prefix>proof/workspaces/</Prefix><IsTruncated>false</IsTruncated></ListBucketResult>`
	for _, test := range []struct {
		name, raw string
		want      bool
	}{
		{"empty", valid, true},
		{"truncated", strings.Replace(valid, "false", "true", 1), false},
		{"wrong-bucket", strings.Replace(valid, "state-fixture", "different", 1), false},
		{"wrong-prefix", strings.Replace(valid, "proof/workspaces/", "different/", 1), false},
		{"duplicate-prefix", strings.Replace(valid, "<Prefix>", "<Prefix>different/</Prefix><Prefix>", 1), false},
		{"duplicate-status", strings.Replace(valid, "<IsTruncated>", "<IsTruncated>true</IsTruncated><IsTruncated>", 1), false},
		{"occupied", strings.Replace(valid, "</ListBucketResult>", "<Contents><Key>retained</Key></Contents></ListBucketResult>", 1), false},
		{"continuation", strings.Replace(valid, "</ListBucketResult>", "<NextContinuationToken>more</NextContinuationToken></ListBucketResult>", 1), false},
		{"second-document", valid + valid, false},
		{"error", `<Error><Code>AccessDenied</Code></Error>`, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := emptyWorkspaceListing([]byte(test.raw), "state-fixture", "proof/workspaces/"); got != test.want {
				t.Fatalf("got %v want %v", got, test.want)
			}
		})
	}
}
