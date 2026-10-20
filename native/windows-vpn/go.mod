module github.com/easyprivacy/easyprivacy/windows-vpn

go 1.27.0

require (
	github.com/Microsoft/go-winio v0.6.2
	golang.org/x/sys v0.49.0
	golang.zx2c4.com/wireguard/windows v1.1.1
)

require (
	golang.org/x/crypto v0.50.0 // indirect
	golang.org/x/text v0.36.0 // indirect
)

replace github.com/lxn/walk => golang.zx2c4.com/wireguard/windows v0.0.0-20260420103851-857e549307fe

replace github.com/lxn/win => golang.zx2c4.com/wireguard/windows v0.0.0-20210224134948-620c54ef6199
