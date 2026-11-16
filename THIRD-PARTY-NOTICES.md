# Third-party notices

The release assets `wuzapi-<os>-<cpu>` (Linux amd64/arm64, Windows amd64, macOS
amd64/arm64) are unmodified builds of
WuzAPI v1.0.9 (https://github.com/asternic/wuzapi, commit `5db48b6`), built with Go 1.26.5:

```
CGO_ENABLED=0 GOOS=<linux|windows|darwin> GOARCH=<amd64|arm64> go build -trimpath -ldflags "-s -w"
```

Checksums are in `SHA256SUMS-wuzapi`. Nothing in this kit changes their source.

## WuzAPI: MIT License

```
MIT License

Copyright (c) 2025 Nicolas Gudiño and contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## whatsmeow: Mozilla Public License 2.0

WuzAPI is built on whatsmeow (https://github.com/tulir/whatsmeow), used unmodified at the
version pinned in WuzAPI v1.0.9's `go.mod`. Its source code is available there, under the
MPL-2.0: https://www.mozilla.org/MPL/2.0/

Other Go modules compiled in are listed, with their licences, in WuzAPI v1.0.9's `go.mod`.
