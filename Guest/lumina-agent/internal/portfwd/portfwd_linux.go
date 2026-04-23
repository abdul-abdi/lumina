//go:build linux

// Linux production wiring — plumbs the real AF_VSOCK listener into
// portfwd.Manager. Kept in its own file with a build tag so the core
// portfwd package stays platform-neutral and testable on any host.
package portfwd

import (
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/vsock"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/wire"
)

// New creates an empty Manager that binds vsock ports via the real
// guest kernel. Tests must use NewWithListen directly so they run on
// platforms without AF_VSOCK.
func New(w *wire.Writer) *Manager {
	return NewWithListen(w, vsock.Listen)
}
