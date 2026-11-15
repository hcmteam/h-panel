package xray

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func TestReadCertificateFileFromRoot(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "cert.pem"), []byte("certificate"), 0o600); err != nil {
		t.Fatal(err)
	}

	got, err := ReadCertificateFileFromRoot(root, "cert.pem")
	if err != nil {
		t.Fatalf("ReadCertificateFileFromRoot(valid path): %v", err)
	}
	if string(got) != "certificate" {
		t.Fatalf("ReadCertificateFileFromRoot(valid path) = %q, want %q", got, "certificate")
	}

	absolute := filepath.Join(root, "cert.pem")
	got, err = ReadCertificateFileFromRoot(root, absolute)
	if err != nil {
		t.Fatalf("ReadCertificateFileFromRoot(absolute path within root): %v", err)
	}
	if string(got) != "certificate" {
		t.Fatalf("ReadCertificateFileFromRoot(absolute path within root) = %q, want %q", got, "certificate")
	}
}

func TestReadCertificateFileFromRootRejectsTraversal(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(filepath.Dir(root), "outside-cert.pem")
	if err := os.WriteFile(outside, []byte("outside"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(outside) })

	paths := []string{
		"../outside-cert.pem",
		outside,
		"%2e%2e%2foutside-cert.pem",
		"%252e%252e%252foutside-cert.pem",
		"..\\outside-cert.pem",
	}
	for _, path := range paths {
		t.Run(path, func(t *testing.T) {
			if _, err := ReadCertificateFileFromRoot(root, path); err == nil {
				t.Fatalf("ReadCertificateFileFromRoot(%q) unexpectedly succeeded", path)
			}
		})
	}
}

func TestCheckConfigCertFilesRejectsUnsafePaths(t *testing.T) {
	paths := []string{
		"../outside-cert.pem",
		"/etc/passwd",
		"%2e%2e%2foutside-cert.pem",
		"%252e%252e%252foutside-cert.pem",
		"..\\outside-cert.pem",
	}
	for _, path := range paths {
		t.Run(path, func(t *testing.T) {
			raw := []byte(`{"tlsSettings":{"certificates":[{"certificateFile":` + strconv.Quote(path) + `}]}}`)
			if err := CheckConfigCertFiles(raw); err == nil {
				t.Fatalf("CheckConfigCertFiles(%q) unexpectedly succeeded", path)
			}
		})
	}
}

func TestReadCertificateFileFromRootRejectsEscapingSymlink(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(t.TempDir(), "outside.pem")
	if err := os.WriteFile(outside, []byte("outside"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "escape.pem")
	if err := os.Symlink(outside, link); err != nil {
		t.Skipf("symlink creation is unavailable: %v", err)
	}
	if _, err := ReadCertificateFileFromRoot(root, "escape.pem"); err == nil {
		t.Fatal("ReadCertificateFileFromRoot followed a symlink outside its root")
	}
}

func TestReadCertificateFileFromRootRejectsOversizedFile(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "large.pem")
	if err := os.WriteFile(path, make([]byte, maxCertFileBytes+1), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadCertificateFileFromRoot(root, "large.pem"); err == nil {
		t.Fatal("ReadCertificateFileFromRoot accepted an oversized certificate")
	}
}
