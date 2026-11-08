package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"

	"tailscale.com/ipn"
)

// sealedStore is tsnet's state (node and machine keys, prefs) sealed at rest with AES-256-GCM
// under a key Kore hands over the control socket (Keychain on a Mac, a 0600 file on a box). The
// file is `magic | nonce | sealed JSON map`, rewritten whole and atomically on each change;
// tsnet writes state rarely.
type sealedStore struct {
	mu    sync.Mutex
	path  string
	aead  cipher.AEAD
	state map[ipn.StateKey][]byte
}

const sealMagic = "KTS1"

var errWrongKey = errors.New("the state key doesn't open the saved state")

func openStore(path string, key []byte) (*sealedStore, error) {
	if len(key) != 32 {
		return nil, errors.New("the state key must be 32 bytes")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	s := &sealedStore{path: path, aead: aead, state: map[ipn.StateKey][]byte{}}
	sealed, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	n := len(sealMagic) + aead.NonceSize()
	if len(sealed) < n || string(sealed[:len(sealMagic)]) != sealMagic {
		return nil, errWrongKey
	}
	plain, err := aead.Open(nil, sealed[len(sealMagic):n], sealed[n:], []byte(sealMagic))
	if err != nil {
		return nil, errWrongKey
	}
	if err := json.Unmarshal(plain, &s.state); err != nil {
		return nil, errWrongKey
	}
	return s, nil
}

func (s *sealedStore) ReadState(id ipn.StateKey) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	bs, ok := s.state[id]
	if !ok {
		return nil, ipn.ErrStateNotExist
	}
	return append([]byte(nil), bs...), nil
}

func (s *sealedStore) WriteState(id ipn.StateKey, bs []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if bs == nil {
		delete(s.state, id)
	} else {
		s.state[id] = append([]byte(nil), bs...)
	}
	return s.save()
}

func (s *sealedStore) save() error {
	plain, err := json.Marshal(s.state)
	if err != nil {
		return err
	}
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	out := append([]byte(sealMagic), nonce...)
	out = s.aead.Seal(out, nonce, plain, []byte(sealMagic))
	clear(plain)
	tmp, err := os.CreateTemp(filepath.Dir(s.path), ".state-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(out); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), s.path)
}
