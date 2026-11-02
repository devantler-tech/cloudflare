package main

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"io"
	"os"
)

func emptyWorkspaceListing(raw []byte, bucket, prefix string) bool {
	if len(raw) > 1<<20 {
		return false
	}
	var listing struct {
		XMLName        xml.Name   `xml:"ListBucketResult"`
		Names          []string   `xml:"Name"`
		Prefixes       []string   `xml:"Prefix"`
		Truncated      []string   `xml:"IsTruncated"`
		Contents       []struct{} `xml:"Contents"`
		CommonPrefixes []struct{} `xml:"CommonPrefixes"`
		Next           []string   `xml:"NextContinuationToken"`
	}
	d := xml.NewDecoder(bytes.NewReader(raw))
	if d.Decode(&listing) != nil || len(listing.Names) != 1 || listing.Names[0] != bucket ||
		len(listing.Prefixes) != 1 || listing.Prefixes[0] != prefix ||
		len(listing.Truncated) != 1 || listing.Truncated[0] != "false" ||
		len(listing.Contents) != 0 || len(listing.CommonPrefixes) != 0 || len(listing.Next) != 0 {
		return false
	}
	for {
		token, err := d.Token()
		if err == io.EOF {
			return true
		}
		if err != nil {
			return false
		}
		whitespace, ok := token.(xml.CharData)
		if !ok || len(bytes.TrimSpace(whitespace)) != 0 {
			return false
		}
	}
}

func main() {
	if len(os.Args) != 3 {
		os.Exit(2)
	}
	raw, err := io.ReadAll(io.LimitReader(os.Stdin, (1<<20)+1))
	if err != nil || !emptyWorkspaceListing(raw, os.Args[1], os.Args[2]) {
		fmt.Fprintln(os.Stderr, "NATIVE_WORKSPACE_LIST=UNVERIFIED")
		os.Exit(2)
	}
	fmt.Println("NATIVE_WORKSPACE_LIST=VERIFIED contents=empty pages=complete")
}
