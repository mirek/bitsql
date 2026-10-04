///|
/// Built-in self-signed certificate (CN=localhost, SAN localhost, 127.0.0.1,
/// ::1; RSA 2048; 2026-01-01..2046-01-01), the stand-in for the certificate
/// SQL Server generates for itself. The key is public: it only exists so
/// that clients with `encrypt: true` and trustServerCertificate connect.
/// Regenerate with:
///   openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem \
///     -not_before 20260101000000Z -not_after 20460101000000Z -subj /CN=localhost \
///     -addext subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1 \
///     -addext extendedKeyUsage=serverAuth
let builtin_certificate : String =
  #|-----BEGIN CERTIFICATE-----
  #|MIIDTjCCAjagAwIBAgIURwxWKAaKb1zFYkAefdvHtsW1JMUwDQYJKoZIhvcNAQEL
  #|BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDEwMTAwMDAwMFoXDTQ2MDEw
  #|MTAwMDAwMFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
  #|AAOCAQ8AMIIBCgKCAQEAs70zv7mTcX7GndEbztn3lf/6HnZkREqMz108qMoCSKnK
  #|1WCCfx2w7ClSiAsigzUrh3JuSomjnQLtqQerHjhDlUNCLS/5HXSdR1Hycs/dJjCZ
  #|Lb9tSCxQhJfVixVrRv8fpQaTw4HHaKWuJSKlNV2BXRJynVUzKdUHBlucbs1IzwKz
  #|9ddDhWm5HRS+gkrFSMFAYz2QXoW708+0/2RvMAZJVFY8HT99DlbWmqQ5SEmDnn2L
  #|REr1lSSauVC9qQTMpF9IpW6ADhf2kZHVz45I5k9oxDuQx++VF6Sq+13Oe2zDKbGq
  #|HRlYOnb4jcxcnPt2dccHfXLy+ffttiDxeMi5kQJGkwIDAQABo4GXMIGUMB0GA1Ud
  #|DgQWBBQ4IKpks8zPKaLvgbJR1/f7fki9UzAfBgNVHSMEGDAWgBQ4IKpks8zPKaLv
  #|gbJR1/f7fki9UzAPBgNVHRMBAf8EBTADAQH/MCwGA1UdEQQlMCOCCWxvY2FsaG9z
  #|dIcEfwAAAYcQAAAAAAAAAAAAAAAAAAAAATATBgNVHSUEDDAKBggrBgEFBQcDATAN
  #|BgkqhkiG9w0BAQsFAAOCAQEAE0wLmfOgMmPnQhQeGLUKsWWGqEgAmsLeSEpt7IH3
  #|aM+b+IjyohPUEJGuRgIU7XgKZ87qDLgSK1C/dYLkLDsb9ogqU65Dx2uZ9hbfdweY
  #|rVuhZqFQ/cJjvJ0bFcDmsMWieCvZzkKs259wmjTjOhlFSRt1HoJW0P31IJbGIAXx
  #|gJlOsNFtLk6Zsj9V+bui/E3iisaxh8qu9CQ/SVu7vtPs1u4I2qa/1Ltx1sHchr17
  #|zJ3rvTqgjICr29dzqVrRZwa3Bu4MKdlieukCAJ637NZP8eWeVGfu5px9aHlD4zzR
  #|QeMCx5p+UioXxoquWefD1xjLZ1X0wyboXvH3g/7LOal/2Q==
  #|-----END CERTIFICATE-----

///|
let builtin_private_key : String =
  #|-----BEGIN PRIVATE KEY-----
  #|MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCzvTO/uZNxfsad
  #|0RvO2feV//oedmRESozPXTyoygJIqcrVYIJ/HbDsKVKICyKDNSuHcm5KiaOdAu2p
  #|B6seOEOVQ0ItL/kddJ1HUfJyz90mMJktv21ILFCEl9WLFWtG/x+lBpPDgcdopa4l
  #|IqU1XYFdEnKdVTMp1QcGW5xuzUjPArP110OFabkdFL6CSsVIwUBjPZBehbvTz7T/
  #|ZG8wBklUVjwdP30OVtaapDlISYOefYtESvWVJJq5UL2pBMykX0ilboAOF/aRkdXP
  #|jkjmT2jEO5DH75UXpKr7Xc57bMMpsaodGVg6dviNzFyc+3Z1xwd9cvL59+22IPF4
  #|yLmRAkaTAgMBAAECggEAAIp2klTFIXVftKJM0FYuSuiepSKt7Ub33ji8ZBDIIIyQ
  #|igyNzIxFHGH2l/k1v05UudhnYUZ4VDcgrvVRTm9UxClK3ebxspvsJ8+3PyFYAGE0
  #|WDpl4koStNACuiOiARTnUIu+l6jOPytxCVttsI6isM7LeaS6onipta1nCi4IZLMT
  #|cOB1PSfriDtoM8UB91N3PEvMMZOJ7Km0jqVT1PnJtBLB8VmZFuZ0ar4GFzP0Xrgb
  #|/VXp+qBBaJO1yPTVaIaxMS09iLAvBJ7LKIxpa8t4vrxrGwOJ4sYYC/1QTE08SfL+
  #|tJkjmgBKB7iGE+Whl7V6ZgWRgX13ZMM11vIfXdHd6QKBgQDvtglaIPonKtpT0tMr
  #|kGfgvVPUhvzlP3nR/h03sxrzSSXeCcrIdm0VhrUE0bGABfBYNeYFqIJF6PX1ngaZ
  #|DHjtCGqaTCxYcwR0VUOzKnK+LzKpwJnmP0e7aEcT3zzV8V78AdlP3Jc4pUJNpQ0K
  #|zGoMvjMyG6e3WTEncc8sRgLKOQKBgQC/8+e5H25mE98sPbSVHVEiZCGoQZUrP8q0
  #|1pdbEduGzygv8nzCCkWxD0hXH9eGefsUb/fcZrhamDKgmzQ/XYqPVfyTywCs7k3g
  #|blUCUaa+hosxwZuJ6G4LMIXl2nOWYTcIwimdABcn1aWsI5wBhOzVkQZS61SJJJ0L
  #|Ab0oHhjHKwKBgBUHHfjnDaqj6rURuG6I42Pml9T75nFhyRjvtrZtIr8WupiouT4u
  #|jVEnGPgMQQre+n9ycvQqHQtu7SyXqTKB0pXQeDGC3xz/MfPWivLLlXczgrk7aQS2
  #|pl89PYbzvU1zOAbZTqvfyPAyJwfSo7s/xUnK4YjSvjqqO1KffDIBDjuZAoGBAL2N
  #|EN25UR6SLwcUJBhALBenA6mQocpkozqy0iIHX14fgVLfxR0kYa+4JLqMYhuUp0GG
  #|VCAce55Sv2Pj/9M2/xYOVm5nv9IFPXgL2/x/PwbT++51fq/Pi6OXFhJmB1CPzXXj
  #|ro4wQa1/h6uWOn8xkWJQZQtLAl6vfjkZTX6pQdSjAoGAVrgf6Y37rH5PYDNBqBWa
  #|CiGabYfAzlx8InBtp51lTCpqZ7dvqIcOQ9OuKhR26CaRq8gnLzK9kS/PmrLmyxpX
  #|Bg5p6PMUm2IeO9+0XJtjd9aoXMDkWsGGhEdZdrVijScldN+WNqCoDuVl9jSVmimD
  #|KgKrxMmXh+fakkEpjncnXs8=
  #|-----END PRIVATE KEY-----
