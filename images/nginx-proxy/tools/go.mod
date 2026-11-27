// Build pins for the two Go binaries in the hardened nginx-proxy (see ../Dockerfile).
// Not a program of its own: docker-gen and forego are Go tool dependencies.
//
// docker-gen v0.0.0-20260711084634-497e50d07d3a is tag 0.17.2 (its tags have no
// "v"); keep DOCKER_GEN_VERSION and DOCKER_GEN_COMMIT in the Dockerfile in step.
//
// Security floors above what docker-gen 0.17.2 and forego v0.18.8 pin, for
// fixable HIGH findings in the Trivy gate: klauspost/compress v1.18.7,
// moby/go-archive v0.3.0, golang.org/x/crypto v0.55.0, golang.org/x/text v0.41.0.
// Once upstream releases require these or newer, the floors are redundant.
module hardened-nginx-proxy/tools

go 1.25.5

tool (
	github.com/nginx-proxy/docker-gen/cmd/docker-gen
	github.com/nginx-proxy/forego
)

require (
	dario.cat/mergo v1.0.2 // indirect
	github.com/Azure/go-ansiterm v0.0.0-20250102033503-faa5f7b0171c // indirect
	github.com/BurntSushi/toml v1.6.0 // indirect
	github.com/Masterminds/goutils v1.1.1 // indirect
	github.com/Masterminds/semver/v3 v3.3.0 // indirect
	github.com/Masterminds/sprig/v3 v3.3.0 // indirect
	github.com/Microsoft/go-winio v0.6.2 // indirect
	github.com/containerd/log v0.1.0 // indirect
	github.com/daviddengcn/go-colortext v1.0.0 // indirect
	github.com/docker/go-units v0.5.0 // indirect
	github.com/fsouza/go-dockerclient v1.13.2 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/huandu/xstrings v1.5.0 // indirect
	github.com/klauspost/compress v1.18.7 // indirect
	github.com/mitchellh/copystructure v1.2.0 // indirect
	github.com/mitchellh/reflectwalk v1.0.2 // indirect
	github.com/moby/go-archive v0.3.0 // indirect
	github.com/moby/moby/api v1.54.2 // indirect
	github.com/moby/moby/client v0.4.1 // indirect
	github.com/moby/patternmatcher v0.6.1 // indirect
	github.com/moby/sys/sequential v0.7.0 // indirect
	github.com/moby/sys/user v0.4.1 // indirect
	github.com/moby/sys/userns v0.1.0 // indirect
	github.com/moby/term v0.5.2 // indirect
	github.com/nginx-proxy/docker-gen v0.0.0-20260711084634-497e50d07d3a // indirect
	github.com/nginx-proxy/forego v0.18.8 // indirect
	github.com/opencontainers/go-digest v1.0.0 // indirect
	github.com/opencontainers/image-spec v1.1.1 // indirect
	github.com/shopspring/decimal v1.4.0 // indirect
	github.com/sirupsen/logrus v1.9.4 // indirect
	github.com/spf13/cast v1.7.0 // indirect
	github.com/subosito/gotenv v1.6.0 // indirect
	golang.org/x/crypto v0.55.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/text v0.41.0 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)
