package tailnet

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
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

// Lost is what a Sealer's Open error says when that state can never open again: its key is gone
// (a restore, a wiped Keystore), or the key there isn't the one that sealed it. Any other Open
// error may pass (the Keystore busy, a locked first boot) and keeps the file.
const Lost = "sealer: lost"

// openSealedStore reads the sealed state. An Open error comes back as an error and the file stays:
// a transient Keystore failure must never sign the phone out. Only a [Lost] state, or a sealed
// file that opens to no state, starts signed out, and even then the old file is set aside
// (state.sealed.lost), never deleted; Leave is the one delete.
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
		if !strings.Contains(err.Error(), Lost) {
			return nil, fmt.Errorf("tailnet: state didn't open (kept): %w", err)
		}
		return s, setAside(path)
	}
	if err := json.Unmarshal(plain, &s.state); err != nil {
		s.state = map[ipn.StateKey][]byte{}
		return s, setAside(path)
	}
	return s, nil
}

func setAside(path string) error {
	if err := os.Rename(path, path+".lost"); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
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
