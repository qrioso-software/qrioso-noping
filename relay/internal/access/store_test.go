package access

import (
	"os"
	"path/filepath"
	"testing"
)

func TestTokenLifecycle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "access-keys.yaml")
	document := EmptyDocument()
	token, err := GenerateToken("cliente-001")
	if err != nil {
		t.Fatal(err)
	}
	if err := Add(&document, "cliente-001", token, 1, "PC de prueba"); err != nil {
		t.Fatal(err)
	}
	if err := WriteAtomic(path, document); err != nil {
		t.Fatal(err)
	}

	loaded, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, ok := Authorize(loaded, token); !ok {
		t.Fatal("expected generated token to be authorized")
	}
	if _, _, ok := Authorize(loaded, token+"x"); ok {
		t.Fatal("expected modified token to be rejected")
	}

	if err := Revoke(&loaded, "cliente-001"); err != nil {
		t.Fatal(err)
	}
	if _, _, ok := Authorize(loaded, token); ok {
		t.Fatal("expected revoked token to be rejected")
	}
}

func TestRejectsUnknownYamlFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "access-keys.yaml")
	contents := []byte("version: 1\nunknown: true\nkeys: {}\n")
	if err := os.WriteFile(path, contents, 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil {
		t.Fatal("expected unknown YAML field to fail")
	}
}
