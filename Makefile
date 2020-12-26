ROOT_NAME = root-ca
SUB_NAME  = sub-ca
SRVR_NAME = server
CLI_NAME  = client

# Add entry after adding new name above.
NAMES = ${ROOT_NAME} ${SUB_NAME} ${SRVR_NAME} ${CLI_NAME}

EC_CURVE = prime256v1

CONF_DIR = ./confs
# TODO: output all certs into this directory.
CERTOUT_DIR = ./certout
# TODO: also collect all keys?

# > PROPOSAL:
# - Rename these directories?
# - Rut all temporary stuffs into something like `stuffs` or `tmp`?

# NOTE: These names are fixed in `root-ca.conf`.
# Where stuffs making certs are stored.
# CA_OBJDIR = ./objs
# Certs generated.
CA_CERTDIR = certs
# Private key storage.
CA_PRIVDIR = private
# Cert-signing datas.
CA_DBDIR   = db
CA_DB_FILES = index serial crlnumber

# TODO: Use identifier other then all cap `SECRET`.
KEY_SECRET_DIR = secret
KEY_NAMES = $(addsuffix .key,${NAMES})
KEY_DST = ${addprefix ${CA_PRIVDIR}/,${KEY_NAMES}}
SECRET_EXT = secret

# NOTE: `-aes256` is not documented in official man page `openssl-ec`
#	but does work on it. Other advanced algorithms are documented in
#	`openssl-rsa` and probably work on `ec` sub-command?
#	This note is written at 20200710.
ifeq (${NO_ENCRYPT_KEY}, 1)
	KEY_ENC = 
else
	KEY_ENC = -aes256
endif

# CSRs generated.
CSR_DIR = csr

# ------------------------------------------------------------------ #
# 	Automatic "yes" for CA signing CSR is enabled (the `-batch`		 #
#	option) for test purpose.										 #
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

${CERTOUT_DIR}:
	mkdir -p $@

# Just want its existence.
# NOTE: If an order-only prereq gets rebuild, the rebuild doesn't
#		propogate?
gen_basedirs: |${CA_DBDIR} ${KEY_SECRET_DIR} ${CERTOUT_DIR}

# --- Keygen2
# The way every keypair is generated, might be other type of key.
# NOTE: no `-hex` opt? we don't care what's inside anyway.
# 		Donno why but making `gen_basedir` a "order-only" prerequisite
#		stops make rebuilding them over and over.
${KEY_DST}: ${CA_PRIVDIR}/%.key: |gen_basedirs
	openssl rand -hex -out ${KEY_SECRET_DIR}/$*.${SECRET_EXT} 16
	openssl ecparam -genkey -name ${EC_CURVE} | \
		openssl ec -out $@ ${KEY_ENC} \
		-passout file:${KEY_SECRET_DIR}/$*.${SECRET_EXT}
# Seems "order-only" req stops rebuild propagating.
# ---

# Certificate generation may seems complicated, but it is just
# simply 2 steps: making CSR and asking CA signing the CSR.
# Certificates are generated after CA approves your CSR.

# --- Gen root CA.
${CSR_DIR}/${ROOT_NAME}.csr: ${CA_PRIVDIR}/${ROOT_NAME}.key
	openssl req -new -config ${CONF_DIR}/${ROOT_NAME}.conf \
		-out $@ \
		-key $< \
		-passin file:${KEY_SECRET_DIR}/${ROOT_NAME}.${SECRET_EXT}

# NOTE: Don't know why `ca` core dumps.
#		*See `root-ca.conf`.
${CERTOUT_DIR}/${ROOT_NAME}.crt: ${CSR_DIR}/${ROOT_NAME}.csr
	openssl ca -selfsign -config ${CONF_DIR}/${ROOT_NAME}.conf \
		-in $< -out $@ \
		-passin file:${KEY_SECRET_DIR}/${ROOT_NAME}.${SECRET_EXT} \
		-extensions ca_selfsign_ext -batch
gen_rootca: ${CERTOUT_DIR}/${ROOT_NAME}.crt


# --- Gen sub CA.
${CSR_DIR}/${SUB_NAME}.csr: ${CA_PRIVDIR}/${SUB_NAME}.key ${ROOT_NAME}.crt
	openssl req -new -config ${CONF_DIR}/${SUB_NAME}.conf \
		-out $@ \
		-key $< \
		-passin file:${KEY_SECRET_DIR}/${SUB_NAME}.${SECRET_EXT}

${CERTOUT_DIR}/${SUB_NAME}.crt: ${CSR_DIR}/${SUB_NAME}.csr
	openssl ca -config ${CONF_DIR}/${ROOT_NAME}.conf \
		-in $< -out $@ \
		-passin file:${KEY_SECRET_DIR}/${ROOT_NAME}.${SECRET_EXT} \
		-extensions sub_ca_sign_ext -batch
gen_sub: ${CERTOUT_DIR}/${SUB_NAME}.crt

# --- Gen server cert.
${CSR_DIR}/${SRVR_NAME}.csr: ${CA_PRIVDIR}/${SRVR_NAME}.key ${SUB_NAME}.crt
	openssl req -new -config ${CONF_DIR}/${SRVR_NAME}-req.conf \
		-out $@ \
		-key $< \
		-passin file:${KEY_SECRET_DIR}/${SRVR_NAME}.${SECRET_EXT}

${CERTOUT_DIR}/${SRVR_NAME}.crt: ${CSR_DIR}/${SRVR_NAME}.csr
	openssl ca -config ${CONF_DIR}/${SUB_NAME}.conf \
		-in $< -out $@ \
		-passin file:${KEY_SECRET_DIR}/${SUB_NAME}.${SECRET_EXT} \
		-extensions server_ext -batch
gen_server: ${CERTOUT_DIR}/${SRVR_NAME}.crt

# TODO: gen_client
# --- Not tested ---
${CSR_DIR}/${CLI_NAME}.csr: ${CA_PRIVDIR}/${CLI_NAME}.key ${SUB_NAME}.crt
	openssl req -new -config ${CONF_DIR}/${CLI_NAME}-req.conf \
		-out $@ \
		-key $< \
		-passin file:${KEY_SECRET_DIR}/${CLI_NAME}.${SECRET_EXT}

${CERTOUT_DIR}/${CLI_NAME}.crt: ${CSR_DIR}/${CLI_NAME}.csr
	openssl ca -config ${CONF_DIR}/${SUB_NAME}.conf \
		-in $< -out $@ \
		-passin file:${KEY_SECRET_DIR}/${SUB_NAME}.${SECRET_EXT} \
		-extensions client_ext -batch
gen_client: ${CERTOUT_DIR}/${CLI_NAME}.crt
# --- Not tested ---

gen_dhparam:
	openssl dhparam -out ./dhparam.pem 2048


# --- Other utils ---
check_chain: ${addsuffix .crt,${CERTOUT_DIR}/${NAMES}}
	openssl verify \
		-CAfile ${CERTOUT_DIR}/root-ca.crt \
		-untrusted ${CERTOUT_DIR}/sub-ca.crt \
		${CERTOUT_DIR}/server.crt

check_client: ${addsuffix .crt,${CERTOUT_DIR}/${NAMES}}
	openssl verify \
		-CAfile ${CERTOUT_DIR}/root-ca.crt \
		-untrusted ${CERTOUT_DIR}/sub-ca.crt \
		${CERTOUT_DIR}/client.crt

clean:
	rm -rf ${CA_CERTDIR} ${CA_DBDIR} ${CA_PRIVDIR} \
		${KEY_SECRET_DIR} ${CSR_DIR} ${CERTOUT_DIR}
	rm -rf *.crt *.csr
