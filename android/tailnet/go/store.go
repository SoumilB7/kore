package tailnet

import (
	"encoding/json"
	"os"
	"sync"

	"tailscale.com/ipn"
)

// sealedStore is tsnet's state (node and machine keys, prefs) as one file sealed by the Keystore:
// read once, written whole (temp file, then rename) on every change.
type sealedStore struct {
	mu     sync.Mutex
	path   string
	sealer Sealer
	state  map[ipn.StateKey][]byte
}

func openSealedStore(path string, sealer Sealer) (*sealedStore, error) {
	s := &sealedStore{path: path, sealer: sealer, state: map[ipn.StateKey][]byte{}}
	sealed, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	plain, err := sealer.Open(sealed)
	if err != nil {
		// A key the Keystore lost (a restore, a wiped key) can't open it: start signed out.
		os.Remove(path)
		return s, nil
	}
	if err := json.Unmarshal(plain, &s.state); err != nil {
		os.Remove(path)
		s.state = map[ipn.StateKey][]byte{}
	}
	return s, nil
}

func (s *sealedStore) ReadState(id ipn.StateKey) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, ok := s.state[id]
	if !ok {
		return nil, ipn.ErrStateNotExist
	}
	return append([]byte(nil), b...), nil
}

func (s *sealedStore) WriteState(id ipn.StateKey, bs []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if bs == nil {
		delete(s.state, id)
	} else {
		s.state[id] = append([]byte(nil), bs...)
	}
	plain, err := json.Marshal(s.state)
	if err != nil {
		return err
	}
	sealed, err := s.sealer.Seal(plain)
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, sealed, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}
