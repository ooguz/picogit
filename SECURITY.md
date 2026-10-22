# Security policy

## Reporting a vulnerability

Report it privately through a GitHub security advisory:
<https://github.com/ooguz/picogit/security/advisories/new>. Please do not
open a public issue, pull request or discussion for it.

In the report, include:
- the version (`picogit --version`) and how picogit was installed: release
  binary for which target, OpenWrt package, or built from source;
- the device or system it runs on;
- how to reproduce the problem;
- what an attacker gains.

A malicious server or repository is in scope: picogit must not write
outside the work tree or into `.git`, leak credentials, or crash on hostile
input (see "Hostile servers and repositories" in the README).
`PICOGIT_TRACE=1` output does not contain tokens, but read it before
attaching it all the same.

The answer comes in the advisory. A confirmed problem is fixed in a new
patch release, and the advisory is published with it, crediting the
reporter unless they prefer otherwise.

## Supported versions

Only the newest release receives fixes. While the major version is 0, a fix
is not backported to an earlier minor release.

## Dependencies

The self-contained binaries embed Lua, zlib, Mbed TLS and the Mozilla CA
list at the versions pinned in [`deps.mk`](deps.mk). A security release of
Mbed TLS or zlib, or a CA bundle change that removes a distrusted
authority, is followed by a picogit patch release. The OpenWrt package
links the system's Mbed TLS, zlib and CA bundle instead, and gets those
fixes through OpenWrt.
