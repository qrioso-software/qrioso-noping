package access

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

const CurrentVersion = 1

var (
	idPattern   = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{2,31}$`)
	hashPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
)

type Entry struct {
	TokenHash  string `yaml:"tokenHash"`
	Enabled    bool   `yaml:"enabled"`
	MaxDevices int    `yaml:"maxDevices"`
	Note       string `yaml:"note,omitempty"`
}

type Document struct {
	Version int              `yaml:"version"`
	Keys    map[string]Entry `yaml:"keys"`
}

func EmptyDocument() Document {
	return Document{Version: CurrentVersion, Keys: map[string]Entry{}}
}

func Load(path string) (Document, error) {
	contents, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return EmptyDocument(), nil
	}
	if err != nil {
		return Document{}, fmt.Errorf("read access file: %w", err)
	}

	var document Document
	decoder := yaml.NewDecoder(strings.NewReader(string(contents)))
	decoder.KnownFields(true)
	if err := decoder.Decode(&document); err != nil {
		return Document{}, fmt.Errorf("decode access file: %w", err)
	}
	if err := ValidateDocument(document); err != nil {
		return Document{}, err
	}
	return document, nil
}

func ValidateDocument(document Document) error {
	if document.Version != CurrentVersion {
		return fmt.Errorf("unsupported access file version %d", document.Version)
	}
	if document.Keys == nil {
		return errors.New("keys must be a map")
	}
	for id, entry := range document.Keys {
		if !idPattern.MatchString(id) {
			return fmt.Errorf("invalid key id %q", id)
		}
		if !hashPattern.MatchString(entry.TokenHash) {
			return fmt.Errorf("key %q has an invalid tokenHash", id)
		}
		if entry.MaxDevices < 1 || entry.MaxDevices > 10 {
			return fmt.Errorf("key %q maxDevices must be between 1 and 10", id)
		}
	}
	return nil
}

func GenerateToken(id string) (string, error) {
	if !idPattern.MatchString(id) {
		return "", fmt.Errorf("invalid key id %q", id)
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", fmt.Errorf("generate secret: %w", err)
	}
	return fmt.Sprintf("qnp_%s_%s", id, base64.RawURLEncoding.EncodeToString(secret)), nil
}

func ParseToken(token string) (id string, err error) {
	parts := strings.SplitN(token, "_", 3)
	if len(parts) != 3 || parts[0] != "qnp" || !idPattern.MatchString(parts[1]) {
		return "", errors.New("invalid token format")
	}
	secret, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(secret) != 32 {
		return "", errors.New("token secret must contain exactly 32 random bytes")
	}
	return parts[1], nil
}

func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return "sha256:" + hex.EncodeToString(sum[:])
}

func Authorize(document Document, token string) (string, Entry, bool) {
	id, err := ParseToken(token)
	if err != nil {
		return "", Entry{}, false
	}
	entry, exists := document.Keys[id]
	if !exists || !entry.Enabled {
		return "", Entry{}, false
	}
	expected := []byte(entry.TokenHash)
	actual := []byte(HashToken(token))
	if len(expected) != len(actual) || subtle.ConstantTimeCompare(expected, actual) != 1 {
		return "", Entry{}, false
	}
	return id, entry, true
}

func Add(document *Document, id, token string, maxDevices int, note string) error {
	if document.Keys == nil {
		document.Keys = map[string]Entry{}
	}
	if _, exists := document.Keys[id]; exists {
		return fmt.Errorf("key %q already exists", id)
	}
	tokenID, err := ParseToken(token)
	if err != nil {
		return err
	}
	if tokenID != id {
		return errors.New("token id does not match --id")
	}
	document.Keys[id] = Entry{
		TokenHash:  HashToken(token),
		Enabled:    true,
		MaxDevices: maxDevices,
		Note:       note,
	}
	return ValidateDocument(*document)
}

func Revoke(document *Document, id string) error {
	if _, exists := document.Keys[id]; !exists {
		return fmt.Errorf("key %q does not exist", id)
	}
	delete(document.Keys, id)
	return nil
}

func SortedIDs(document Document) []string {
	ids := make([]string, 0, len(document.Keys))
	for id := range document.Keys {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

func WriteAtomic(path string, document Document) error {
	if err := ValidateDocument(document); err != nil {
		return err
	}
	contents, err := yaml.Marshal(document)
	if err != nil {
		return fmt.Errorf("encode access file: %w", err)
	}

	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o750); err != nil {
		return fmt.Errorf("create access directory: %w", err)
	}
	temporary, err := os.CreateTemp(directory, ".access-keys-*")
	if err != nil {
		return fmt.Errorf("create temporary access file: %w", err)
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)

	if err := preserveOwnership(temporary, path, directory); err != nil {
		temporary.Close()
		return fmt.Errorf("preserve access file ownership: %w", err)
	}
	if err := temporary.Chmod(0o640); err != nil {
		temporary.Close()
		return fmt.Errorf("chmod temporary access file: %w", err)
	}
	if _, err := temporary.Write(contents); err != nil {
		temporary.Close()
		return fmt.Errorf("write temporary access file: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return fmt.Errorf("sync temporary access file: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close temporary access file: %w", err)
	}
	if err := os.Rename(temporaryName, path); err != nil {
		return fmt.Errorf("replace access file: %w", err)
	}

	directoryHandle, err := os.Open(directory)
	if err == nil {
		defer directoryHandle.Close()
		if syncErr := directoryHandle.Sync(); syncErr != nil {
			return fmt.Errorf("sync access directory: %w", syncErr)
		}
	}
	return nil
}
