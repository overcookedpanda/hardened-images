#!/bin/sh
# Entrypoint for the hardened nginx-proxy: nginx-proxy 1.11.6's app/docker-entrypoint.sh
# rewritten for POSIX sh. The hardened base has busybox but no bash, and this
# keeps the same behaviour:
#
#   * init (socket check, RESOLVERS, DH params, TRUST_DOWNSTREAM_PROXY warning,
#     $NGINX_CONTAINER_LABEL substitution) runs only for the default command or
#     a `docker-gen -watch` command line, as upstream;
#   * anything else is exec'd untouched. acme-companion relies on that: to
#     reload, it execs
#       sh -c "/app/docker-entrypoint.sh /usr/local/bin/docker-gen /app/nginx.tmpl /etc/nginx/conf.d/default.conf; /usr/sbin/nginx -s reload"
#     in this container.
set -e

_parse_true() {
	case "$1" in
		true | True | TRUE | 1) return 0 ;;
		*) return 1 ;;
	esac
}

_parse_false() {
	case "$1" in
		false | False | FALSE | 0) return 0 ;;
		*) return 1 ;;
	esac
}

_print_version() {
	if [ -n "${NGINX_PROXY_VERSION:-}" ]; then
		echo "Info: running nginx-proxy version ${NGINX_PROXY_VERSION}"
	fi
}

_check_unix_socket() {
	# Fail if the DOCKER_HOST socket does not exist
	case "${DOCKER_HOST:-}" in
		unix://*)
			SOCKET_FILE="${DOCKER_HOST#unix://}"
			if [ ! -S "${SOCKET_FILE}" ]; then
				cat >&2 <<-EOT
					ERROR: you need to share your Docker host socket with a volume at ${SOCKET_FILE}
					Typically you should run this image with: \`-v /var/run/docker.sock:${SOCKET_FILE}:ro\`
					See the documentation at: https://github.com/nginx-proxy/nginx-proxy/#usage
				EOT
				exit 1
			fi
			;;
	esac
}

_resolvers() {
	# Honor a user-provided RESOLVERS value and only autodetect the DNS
	# resolvers from /etc/resolv.conf when it has not been set.
	if [ -n "${RESOLVERS:-}" ]; then
		export RESOLVERS
		return
	fi

	# IPv6 resolvers (containing ":") must be enclosed in []
	RESOLVERS=$(awk '$1 == "nameserver" {print ($2 ~ ":")? "["$2"]": $2}' ORS=' ' /etc/resolv.conf | sed 's/ *$//g')
	export RESOLVERS

	SCOPED_IPV6_REGEX='\[fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}\]'

	if [ -z "${RESOLVERS}" ]; then
		echo 'Warning: unable to determine DNS resolvers for nginx' >&2
		unset RESOLVERS
	elif printf '%s\n' "${RESOLVERS}" | grep -Eq "${SCOPED_IPV6_REGEX}"; then
		printf 'Warning: Scoped IPv6 addresses removed from resolvers: %s\n' \
			"$(printf '%s\n' "${RESOLVERS}" | grep -Eo "${SCOPED_IPV6_REGEX}" | tr '\n' ' ' | sed 's/ *$//')" >&2
		# Drop the scoped addresses and squeeze the spaces left behind.
		RESOLVERS=$(printf '%s\n' "${RESOLVERS}" | sed -E "s/${SCOPED_IPV6_REGEX}//g" | awk '{$1=$1; print}')
		export RESOLVERS
	fi
}

_setup_dhparam() {
	# DH params will be supplied for nginx here:
	DHPARAM_FILE='/etc/nginx/dhparam/dhparam.pem'

	# Should be 2048, 3072, or 4096 (default):
	DHPARAM_BITS="${DHPARAM_BITS:-4096}"

	if [ -f "${DHPARAM_FILE}" ]; then
		echo 'Warning: A custom dhparam.pem file was provided. Best practice is to use standardized RFC7919 DHE groups instead.' >&2
		return 0
	elif _parse_true "${DHPARAM_SKIP:-false}"; then
		echo 'Skipping Diffie-Hellman parameters setup.'
		return 0
	elif _parse_false "${DHPARAM_GENERATION:-true}"; then
		echo 'Warning: The DHPARAM_GENERATION environment variable is deprecated, please consider using DHPARAM_SKIP set to true instead.' >&2
		echo 'Skipping Diffie-Hellman parameters setup.'
		return 0
	fi
	case "${DHPARAM_BITS}" in
		2048 | 3072 | 4096) ;;
		*)
			echo "ERROR: Unsupported DHPARAM_BITS size: ${DHPARAM_BITS}. Use: 2048, 3072, or 4096 (default)." >&2
			exit 1
			;;
	esac

	echo 'Setting up DH Parameters..'

	# Pre-generated DH group from RFC7919 (https://datatracker.ietf.org/doc/html/rfc7919#appendix-A)
	cp "/app/dhparam/ffdhe${DHPARAM_BITS}.pem" "${DHPARAM_FILE}"
}

# Run the init logic if the default CMD was provided
run_init=false
case " $* " in
	' forego start -r ') run_init=true ;;
	*'docker-gen -watch'*) run_init=true ;;
esac

if [ "${run_init}" = true ]; then
	_print_version

	_check_unix_socket

	_resolvers

	_setup_dhparam

	if [ -z "${TRUST_DOWNSTREAM_PROXY:-}" ]; then
		cat >&2 <<-EOT
			Warning: TRUST_DOWNSTREAM_PROXY is not set; defaulting to "true". For security, you should explicitly set TRUST_DOWNSTREAM_PROXY to "false" if there is not a trusted reverse proxy in front of this proxy.
			Warning: The default value of TRUST_DOWNSTREAM_PROXY might change to "false" in a future version of nginx-proxy. If you require TRUST_DOWNSTREAM_PROXY to be enabled, explicitly set it to "true".
		EOT
	fi

	# Replace the first $NGINX_CONTAINER_LABEL in each argument with the
	# value of the environment variable (upstream's ${arg/pattern/value}).
	if [ -n "${NGINX_CONTAINER_LABEL:-}" ]; then
		for arg do
			shift
			case "${arg}" in
				*'$NGINX_CONTAINER_LABEL'*)
					arg="${arg%%\$NGINX_CONTAINER_LABEL*}${NGINX_CONTAINER_LABEL}${arg#*\$NGINX_CONTAINER_LABEL}"
					;;
			esac
			set -- "$@" "${arg}"
		done
	fi
fi

exec "$@"
