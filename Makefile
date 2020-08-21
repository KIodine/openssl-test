ROOT_NAME = root-ca
SUB_NAME  = sub-ca
SRVR_NAME = server
CLI_NAME  = client

# Add entry after adding new name above.
NAMES = ${ROOT_NAME} ${SUB_NAME} ${SRVR_NAME} ${CLI_NAME}

EC_CURVE = prime256v1

CONF_DIR = ./confs

# > PROPOSAL: rename these directories?
# NOTE: These names are fixed in `root-ca.conf`.
# Certs generated.
CA_CERTDIR = certs
# Private key storage.
CA_PRIVDIR = private
# Cert-signing datas.
CA_DBDIR   = db
CA_DB_FILES = index serial crlnumber

KEY_SECRET_DIR = secret
KEY_NAMES = $(addsuffix .key,${NAMES})
KEY_DST = ${addprefix ${CA_PRIVDIR}/,${KEY_NAMES}}

ifeq (${NO_ENCRYPT_KEY}, 1)
	KEY_ENC = 
else
	# NOTE: `-aes256` is not documented in official man page `openssl-ec`
	#	but does work on it. Other advanced algorithms are documented in
	#	`openssl-rsa` and probably work on `ec` sub-command?
	#	This note is written at 20200710.
	KEY_ENC = -aes256
endif

# CSRs generated.
CSR_DIR = csr

# ------------------------------------------------------------------ #
# 	Automatic "yes" for CA signing CSR is enabled (the `-batch`
#	option) for test purpose.
# ------------------------------------------------------------------ #

# TODO: Fix key rebuild issue (target not precisely specified).

# Build up dirs.
${CA_DBDIR}:
	mkdir -p ${CA_CERTDIR} ${CA_PRIVDIR} ${CA_DBDIR} ${CSR_DIR}
	chmod 0700 ${CA_PRIVDIR}
	touch ${CA_DBDIR}/index
	openssl rand -hex 16 > ${CA_DBDIR}/serial
	echo 1001 > ${CA_DBDIR}/crlnumber

${KEY_SECRET_DIR}:
	mkdir -p $@
	chmod 0700 $@

# Just want its existence.
# NOTE: If an order-only prereq gets rebuild, the rebuild doesn't
#		propogate?
gen_basedirs: |${CA_DBDIR} ${KEY_SECRET_DIR}

# --- Keygen2
# NOTE: no `-hex` opt? we don't care what's inside anyway.
# 		Donno why but making `gen_basedir` a "order-only" prerequisite
#		stops make rebuilding them over and over.
${KEY_DST}: ${CA_PRIVDIR}/%.key: |gen_basedirs
	openssl rand -hex -out ${KEY_SECRET_DIR}/$*.SECRET 16
	openssl ecparam -genkey -name ${EC_CURVE} | \
		openssl ec -out $@ ${KEY_ENC} \
		-passout file:${KEY_SECRET_DIR}/$*.SECRET
# Seems "order-only" req stops rebuild propagating.
# ---

# --- Gen root CA.
${CSR_DIR}/${ROOT_NAME}.csr: ${CA_PRIVDIR}/${ROOT_NAME}.key
	openssl req -new -config ${CONF_DIR}/${ROOT_NAME}.conf \
		-out $@ \
		-key $< \
		-passin file:${KEY_SECRET_DIR}/${ROOT_NAME}.SECRET

# NOTE: Don't know why `ca` core dumps.
#		*See `root-ca.conf`.
${ROOT_NAME}.crt: ${CSR_DIR}/${ROOT_NAME}.csr
	openssl ca -selfsign -config ${CONF_DIR}/${ROOT_NAME}.conf \
		-in $< -out $@ \
		-passin file:${KEY_SECRET_DIR}/${ROOT_NAME}.SECRET \
		-extensions ca_selfsign_ext -batch
gen_rootca: ${ROOT_NAME}.crt


# --- Gen sub CA.
${CSR_DIR}/${SUB_NAME}.csr: ${CA_PRIVDIR}/${SUB_NAME}.key ${ROOT_NAME}.crt
	openssl req -new -config ${CONF_DIR}/${SUB_NAME}.conf \
		-out $@ \
		-key $< \
		-passin file:${KEY_SECRET_DIR}/${SUB_NAME}.SECRET

${SUB_NAME}.crt: ${CSR_DIR}/${SUB_NAME}.csr
	openssl ca -config ${CONF_DIR}/${ROOT_NAME}.conf \
		-in $< -out $@ \
		-passin file:${KEY_SECRET_DIR}/${ROOT_NAME}.SECRET \
		-extensions sub_ca_sign_ext -batch
gen_sub: ${SUB_NAME}.crt

# --- Gen server cert.
${CSR_DIR}/${SRVR_NAME}.csr: ${CA_PRIVDIR}/${SRVR_NAME}.key ${SUB_NAME}.crt
	openssl req -new -config ${CONF_DIR}/${SRVR_NAME}-req.conf \
		-out $@ \
		-key $< \
		-passin file:${KEY_SECRET_DIR}/${SRVR_NAME}.SECRET

${SRVR_NAME}.crt: ${CSR_DIR}/${SRVR_NAME}.csr
	openssl ca -config ${CONF_DIR}/${SUB_NAME}.conf \
		-in $< -out $@ \
		-passin file:${KEY_SECRET_DIR}/${SUB_NAME}.SECRET \
		-extensions server_ext -batch
gen_server: ${SRVR_NAME}.crt

# TODO: gen_client
# --- Not tested ---
${CSR_DIR}/${CLI_NAME}.csr: ${CA_PRIVDIR}/${CLI_NAME}.key ${SUB_NAME}.crt
	openssl req -new -config ${CONF_DIR}/${CLI_NAME}-req.conf \
		-out $@ \
		-key $< \
		-passin file:${KEY_SECRET_DIR}/${CLI_NAME}.SECRET

${CLI_NAME}.crt: ${CSR_DIR}/${CLI_NAME}.csr
	openssl ca -config ${CONF_DIR}/${SUB_NAME}.conf \
		-in $< -out $@ \
		-passin file:${KEY_SECRET_DIR}/${SUB_NAME}.SECRET \
		-extensions client_ext -batch
gen_client: ${CLI_NAME}.crt
# --- Not tested ---

gen_dhparam:
	openssl dhparam -out ./dhparam.pem 2048


# --- Other utils ---
check_chain: ${addsuffix .crt,${NAMES}}
	openssl verify \
		-CAfile root-ca.crt \
		-untrusted sub-ca.crt \
		server.crt

check_client: ${addsuffix .crt,${NAMES}}
	openssl verify \
		-CAfile root-ca.crt \
		-untrusted sub-ca.crt \
		client.crt

clean:
	rm -rf ${CA_CERTDIR} ${CA_DBDIR} ${CA_PRIVDIR} \
		${KEY_SECRET_DIR} ${CSR_DIR}
	rm -rf *.crt *.csr
