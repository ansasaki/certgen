#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   lib.sh of /CoreOS/openssl/Library/certgen
#   Description: Library for creating X.509 certificates for any use
#   Author: Hubert Kario <hkario@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2014 Red Hat, Inc.
#
#   This copyrighted material is made available to anyone wishing
#   to use, modify, copy, or redistribute it subject to the terms
#   and conditions of the GNU General Public License version 2.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE. See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public
#   License along with this program; if not, write to the Free
#   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
#   Boston, MA 02110-1301, USA.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   library-prefix = x509
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 NAME

openssl/certgen - Library for creating X.509 certificates for any use

=head1 DESCRIPTION

This is a library aimed at making X.509 certificate creation simple without
sacrificing advanced functionality.

Typical use cases won't require any additional options and even complex
PKI structure for TLS can be created with just few commands.

Note that it assumes that all generated keys and certificates can be used as
CAs (even if they have extensions that specifically forbid it). Because of
that, every single key pair is placed in a separate directory named after its
alias.

This library uses I<getopt> for option parsing, as such the order of options
to functions is not significant unless noted.

=cut

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Variables
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 VARIABLES

Below is the list of global variables. If they are already defined in
environment when the library is loaded, they will NOT be overwritten.

=over

=item B<x509CACNF>

Name of the configuration file for CA operation and CSR generation.
F<ca.cnf> by default.

=item B<x509CAINDEX>

Name of the file with information about all the previously generated
certificates. F<index.txt> by default.

=item B<x509CASERIAL>

Name of the file with next available serial number. F<serial> by default.

=item B<x509CERT>

Name of file in which certificates will be placed. F<cert.pem> by default

=item B<x509CSR>

Name of the file with certificate signing request. F<request.csr> by default.

=item B<x509DERCERT>

Name of the file where certificates encoded in DER format will be placed.
F<cert.crt> by default. Note that those files are generated on demand only by
B<x509Cert> function.

=item B<x509DERKEY>

Name of the file where private keys encoded in DER format will be placed.
F<key.key> by default. Note that those file are generated on demand only by
B<x509Key> function.

=item B<x509FIRSTSERIAL>

The first serial number that will be assigned to the certificate.
Used when the CA self signes its certificate or when intermediate CA signes
it first certificate. Must be a valid, nonegative hex number.
C<01> by default.

=item B<x509FORMAT>

Formatting required by the I<openssl> tool for generating certificates.
For RHEL6 and later it should be set to C<+%Y%m%d%H%M%SZ>.
For RHEL5 it should be set to C<+%y%m%d%H%M%SZ>.

Defaults to version supported by locally installed OpenSSL

=item B<x509PKCS8KEY>
Name of the file where private keys in PKCS#8 format will be placed.
F<pkcs8.pem> by default. Note that those files are generated on demand
only by B<x509Key> function.

=item B<x509PKCS8DERKEY>
Name of the file where private keys in PKCS#8 DER format will be placed.
F<pkcs8.key> by default. Note that those files are generated on demand only
by B<x509Key> function.

=item B<x509PKCS12>

Name of the file where certificates and keys in PKCS#12 format will be placed.
F<bundle.p12> by default. Not that those files are generated on demand only
by B<x509Key> and B<x509Cert> functions.

=item B<x509PKEY>

Name of file with private and public key. F<key.pem> by default

=item B<x509OPENSSL>

Path to the openssl tool used as the backend. F<openssl> by default.

=back

Note that changing the values of above variables between running different
functions may cause the library to misbehave.

=cut

x509PKEY=${x509PKEY:-key.pem}
x509DERKEY=${x509DERKEY:-key.key}
x509CERT=${x509CERT:-cert.pem}
x509DERCERT=${x509DERCERT:-cert.crt}
x509PKCS8KEY=${x509PKCS8KEY:-pkcs8.pem}
x509PKCS8DERKEY=${x509PKCS8DERKEY:-pkcs8.key}
x509PKCS12=${x509PKCS12:-bundle.p12}
x509CSR=${x509CSR:-request.csr}
x509CACNF=${x509CACNF:-ca.cnf}
x509CAINDEX=${x509CAINDEX:-index.txt}
x509CASERIAL=${x509CASERIAL:-serial}
x509FIRSTSERIAL=${x509FIRSTSERIAL:-01}
x509OPENSSL=${x509OPENSSL:-openssl}
if ${x509OPENSSL} version | grep -q '0[.]9[.].'; then
    x509FORMAT=${x509FORMAT:-+%y%m%d%H%M%SZ}
else
    x509FORMAT=${x509FORMAT:-+%Y%m%d%H%M%SZ}
fi

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Internal Functions
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

__INTERNAL_x509GenConfig() {

    # variable that has the DN broken up by items, most significant first
    declare -a dn
    # hash used to sign the certificate
    if ${x509OPENSSL} version | grep -q '0[.]9[.]7'; then
        local md="sha1"
    else
        local md="sha256"
    fi
    # current time in seconds from UNIX epoch
    local now=$(date '+%s')
    # date before which the certificate is not valid
    local notBefore=""
    # date after which the certificate is not valid
    local notAfter=""
    # Basic Key Usage to set
    local basicKeyUsage=""
    # Basic Constraints to set
    local basicConstraints=""
    # value of the Subject Key Identifier extension
    local subjectKeyIdentifier=""
    # whatever to generate Authority Key Identifier extension
    local authorityKeyIdentifier=""
    # variable that has the Subject Alternative Name split by lines
    declare -a subjectAltName
    # variable to set when the Subject Alternative Name is to be marked critical
    local subjectAltNameCritical=""
    # variable to store Authority Info Access (OCSP responder and CA file loc.)
    declare -a authorityInfoAccess
    # value of the Extended Key Usage extension
    local extendedKeyUsage=""
    # list of all the arbitrary X509v3 extensions
    declare -a x509v3Extension

    #
    # parse options
    #

    local TEMP=$(getopt -o t: -l dn: -l md: -l notBefore: -l notAfter: \
        -l basicKeyUsage: \
        -l basicConstraints: \
        -l subjectKeyIdentifier \
        -l authorityKeyIdentifier: \
        -l subjectAltName: \
        -l subjectAltNameCritical \
        -l authorityInfoAccess: \
        -l extendedKeyUsage: \
        -l x509v3Extension: \
        -n x509GenConfig -- "$@")
    if [ $? -ne 0 ]; then
        echo "x509GenConfig: can't parse options" >&2
        return 1
    fi

    eval set -- "$TEMP"

    while true ; do
        case "$1" in
            --dn) dn=("${dn[@]}" "$2"); shift 2
                ;;
            --md) md="$2"; shift 2
                ;;
            --notBefore) notBefore="$2"; shift 2
                ;;
            --notAfter) notAfter="$2"; shift 2
                ;;
            --basicKeyUsage) basicKeyUsage="$2"; shift 2
                ;;
            --basicConstraints) basicConstraints="$2"; shift 2
                ;;
            --subjectKeyIdentifier) subjectKeyIdentifier="true"; shift 1
                ;;
            --authorityKeyIdentifier) authorityKeyIdentifier="$2"; shift 2
                ;;
            --subjectAltName) subjectAltName=("${subjectAltName[@]}" "$2"); shift 2
                ;;
            --authorityInfoAccess) authorityInfoAccess=("${authorityInfoAccess[@]}" "$2"); shift 2
                ;;
            --extendedKeyUsage) extendedKeyUsage="$2"; shift 2
                ;;
            --x509v3Extension) x509v3Extension="$2"; shift 2
                ;;
            --subjectAltNameCritical) subjectAltNameCritical="critical,";
                shift 1
                ;;
            --) shift 1
                break
                ;;
            *) echo "x509GenConfig: Unknown option: \"$1\"" >&2
                return 1
        esac
    done

    local kAlias="$1"

    #
    # sanity check
    #

    if [ ! -e "$kAlias" ]; then
        echo "x509GenConfig: to gen config, the directory must be present" >&2
        return 1
    fi
    if [ ${#dn[@]} -lt 1 ]; then
        echo "x509GenConfig: at least one element in DN must be present" >&2
        return 1
    fi

    #
    # process options
    #

    if [ -z "$notBefore" ]; then
        notBefore="now"
    fi
    notBefore=$(date -d "$notBefore" -u $x509FORMAT)
    if [ $? -ne 0 ]; then
        echo "x509GenConfig: notBefore date value is invalid" >&2
        return 1
    fi

    if [ -z "$notAfter" ]; then
        notAfter="1 year"
    fi
    notAfter=$(date -d "$notAfter" -u $x509FORMAT)
    if [ $? -ne 0 ]; then
        echo "x509GenConfig: notAfter date value is invalid" >&2
        return 1
    fi

    #
    # for Ed25519 we can't specify a hash as it is built-in
    #
    if ${x509OPENSSL} pkey -in "$kAlias/$x509PKEY" -noout -text 2> /dev/null | grep -qE '^(ED25519|ED448)'; then
        md="null"
    fi

    # in openssl 1.1.1 the oid was renamed to uppercase and the
    # lower case stopped working, so fix it
    if ! ${x509OPENSSL} version | grep -Eq '0[.]9[.]|1[.]0[.]'; then
        extendedKeyUsage="${extendedKeyUsage/ocspSigning/OCSPSigning}"
    fi

    #
    # generate config
    #

    touch "$kAlias/$x509CAINDEX"
    echo "unique_subject = no" >> "$kAlias/$x509CAINDEX.attr"
    if [ ! -e $kAlias/$x509CASERIAL ]; then
        echo $x509FIRSTSERIAL > $kAlias/$x509CASERIAL
    fi

    # OpenSSL 1.1.0 (? 1.1.1 definitely has) has the OID definition
    if ${x509OPENSSL} version | grep -Eq '0[.]9[.]|1[.]0[.]'; then
        cat > "$kAlias/$x509CACNF" <<EOF
oid_section = new_oids

[ new_oids ]
ocspSigning = 1.3.6.1.5.5.7.3.9
noCheck = 1.3.6.1.5.5.7.48.1.5

EOF
    else
        cat /dev/null > "$kAlias/$x509CACNF"
    fi
    cat >> "$kAlias/$x509CACNF" <<EOF
[ ca ]
default_ca = ca_cnf

[ ca_cnf ]
default_md = $md
default_startdate = $notBefore
default_enddate   = $notAfter
policy = policy_anything
preserve = yes
email_in_dn = no
unique_subject = no
database = $kAlias/$x509CAINDEX
serial = $kAlias/$x509CASERIAL
new_certs_dir = $kAlias/

[ policy_anything ]
#countryName             = optional
#stateOrProvinceName     = optional
#localityName            = optional
#organizationName        = optional
#organizationalUnitName  = optional
commonName              = optional
#emailAddress            = optional

[ req ]
prompt = no
distinguished_name = cert_req

[ cert_req ]
EOF

    for item in "${dn[@]}"; do
        echo "$item" >> "$kAlias/$x509CACNF"
    done

    cat >> "$kAlias/$x509CACNF" <<EOF

[ v3_ext ]
EOF

    if [[ ! -z $basicConstraints ]]; then
        echo "basicConstraints =$basicConstraints" >> "$kAlias/$x509CACNF"
    fi

    if [[ ! -z $basicKeyUsage ]]; then
        echo "keyUsage =$basicKeyUsage" >> "$kAlias/$x509CACNF"
    fi

    if [[ ! -z $extendedKeyUsage ]]; then
        echo "extendedKeyUsage =$extendedKeyUsage" >> "$kAlias/$x509CACNF"
    fi

    if [[ ! -z $subjectKeyIdentifier ]]; then
        echo "subjectKeyIdentifier=hash" >> "$kAlias/$x509CACNF"
    fi

    if [[ ! -z $authorityKeyIdentifier ]]; then
        echo "authorityKeyIdentifier=$authorityKeyIdentifier" >> "$kAlias/$x509CACNF"
    fi

    if [[ ${#subjectAltName[@]} -ne 0 ]]; then
        echo "subjectAltName =${subjectAltNameCritical} @alt_name" \
            >> "$kAlias/$x509CACNF"
    fi

    if [[ ${#authorityInfoAccess[@]} -ne 0 ]]; then
        local aia_val=""
        local separator=""
        for aia in "${authorityInfoAccess[@]}"; do
            aia_val="${aia_val}${separator}${aia}"
            separator=","
        done
        echo "authorityInfoAccess = $aia_val" >> "$kAlias/$x509CACNF"
    fi

    local ext
    for ext in "${x509v3Extension[@]}"; do
        echo "$ext" >> "$kAlias/$x509CACNF"
    done

    # subject alternative name section

    if [[ ${#subjectAltName[@]} -ne 0 ]]; then
        echo "" >> "$kAlias/$x509CACNF"
        echo "[ alt_name ]" >> "$kAlias/$x509CACNF"

        for name in "${subjectAltName[@]}"; do
            echo "$name" >> "$kAlias/$x509CACNF"
        done
    fi

}

# Converts object (to be name constrained) to syntax understood
# by openssl.cnf
__INTERNAL_x509NameToConstraint() {
    local name="$1"
    local result=""
    if echo "$name" | grep -q '[A-Z]\+:.\+'; then
        result="$name"
    elif echo "$name" | grep -q '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        result="IP:$name/255.255.255.255"
    else
        result="DNS:$name"
    fi
    echo $result
}

# Converts array of objects (to be name constrained) to specification
# for openssl.cnf
__INTERNAL_x509NamesToNCs() {
    local -a names=("${!1}")
    local keyword=$2
    local -a constraints
    local result=""
    for name in "${names[@]}"; do
        local constraint=$(__INTERNAL_x509NameToConstraint "$name")
        constraints=("${constraints[@]}" "$keyword;$constraint")
    done
    oldIFS="$IFS"
    IFS=,
    result="${constraints[*]}"
    IFS="$oldIFS"
    echo "$result"
}


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Functions
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 FUNCTIONS

=head2 x509KeyGen()

Generate new key pair using given algorithm and key size.
By default it generates RSA key of the smallest size aceptable in FIPS mode
(currently 2048 bit).

=over 4

B<x509KeyGen>
[B<-t> I<type>]
[B<-s> I<size>]
[B<--params> I<alias>]
[B<--conservative>]
[B<--anti-conservative>]
[B<--gen-opts> I<opts>]
I<alias>

=back

=over

=item B<-t> I<type>

Type of key pair to generate. Acceptable values are I<RSA> and I<DSA>. In
case the script is running on RHEL 6.5, RHEL 7.0, Fedora 19 or later, I<ECDSA>
is also supported. For I<RSA-PSS>, OpenSSL 1.1.1 is required.

I<RSA> by default.

=item B<-s> I<size>

Size of the used key for RSA and DSA. Name of the elliptic curve in case
of ECDSA key.

By default 2048 bit in case of RSA and DSA and C<prime256v1> in case of
ECDSA.

Other valid names for ECDSA curves can be acquired by running

    openssl ecparam -list_curves

=item B<--params> I<alias>

Reuse DSA parameters from another certificate (usually the CA that will later
sign the certificate).

=item B<--conservative>

Because some implementations incorrectly infer the strength of DSA keys from
the public key value instead of the prime P, they will fail to process
parameters of size smaller than the 1024, 2048 or 3072 bit defined in the
standard.

With this option both the PQG parameters and the public key value will be
regenerated until the most significant bit for all of the 4 values is set.

Note that this is just a workaround for RHBZ#1238279 and RHBZ#1238290, and
should not be used by default.

=item B<--anti-conservative>

Generate a set of parameters that will fail if the implementation checks the
size of PQG DSA parameters incorrecty - the G parameter won't have its MSB set.

This is sort-of reverse of --conservative, the default behaviour is to generate
a set of paramters randomly.

=item B<--gen-opts> I<opts>

Set additional key generation options for non rsa, dsa and ec key generation.

Example options include I<rsa_pss_keygen_md:digest> for RSA-PSS keygen.

=item I<alias>

Name of directory in which the generated key pair will be placed.
The file with key will be named F<key.pem> if the variable I<x509PKEY> was
not changed. If the directory does not exist it will be created. Please don't
put any files in it as they may be overwritten by running functions.

=back

Returns 0 if the key generation was successful. Non zero otherwise.

=cut

x509KeyGen() {

    # type of key to generate
    local kType="RSA"
    # size of key to generate
    local kSize=""
    # name of key to generate
    local kAlias
    # name of key alias with parameters to reuse
    local paramAlias=""
    # name of file with DSA parameters
    local dsaParams=""
    # whether to gen "safer" parameters
    local conservative="False"
    # whether to gen unsafe paramters that are known to break interoperability
    local incompatible="False"
    # additional options for keygen
    local genpkeyOpts
    declare -a genpkeyOpts
    genpkeyOpts=()

    #
    # parse options
    #

    local TEMP=$(getopt -o t:s: -l params: \
                 -l conservative \
                 -l anti-conservative \
                 -l gen-opts: \
                 -n x509KeyGen -- "$@")
    if [ $? -ne 0 ]; then
        echo "x509KeyGen: can't parse options" >&2
        return 1
    fi

    eval set -- "$TEMP"

    while true ; do
        case "$1" in
            -t) kType="$2"; shift 2
                ;;
            -s) kSize="$2"; shift 2
                ;;
            --params) paramAlias="$2"; shift 2
                ;;
            --conservative) conservative="True"; shift 1
                ;;
            --anti-conservative) incompatible="True"; shift 1
                ;;
            --gen-opts) genpkeyOpts=("${genpkeyOpts[@]}" \
                                     "-pkeyopt" "$2")
                shift 2
                ;;
            --) shift 1
                break
                ;;
            *) echo "x509KeyGen: Unknown option: '$1'" >&2
                return 1
        esac
    done

    kAlias="$1"

    #
    # sanity check options
    #

    #upper case and lower case
    kType=$(tr '[:lower:]' '[:upper:]' <<< ${kType})
    kSize=$(tr '[:upper:]' '[:lower:]' <<< ${kSize})

    if [[ -z $kType ]]; then
        echo "x509KeyGen: Key type can't be empty" >&2
        return 1
    fi
    if [[ $kType != "RSA" ]] && [[ $kType != "DSA" ]] \
        && [[ $kType != "ECDSA" ]] && [[ $kType != "RSA-PSS" ]] \
        && [[ $kType != "ED25519" ]] && [[ $kType != "ED448" ]]; then

        echo "x509KeyGen: Unknown key type: $kType" >&2
        return 1
    fi
    if [[ -z $kSize ]]; then
        if [[ $kType == "ECDSA" ]]; then
            kSize="prime256v1"
        else
            kSize="2048"
        fi
    fi

    if [[ $conservative == "True" && $incompatible == "True" ]]; then
        echo "x509KeyGen: can't do conservative and anti-conservative at once" >&2
        return 1
    fi

    if [[ -z $kAlias ]]; then
        echo "x509KeyGen: No certificate alias specified" >&2
        return 1
    fi

    #
    # Generate the key
    #

    mkdir -p "$kAlias"

    if [[ $kType == "ECDSA" ]]; then
        ${x509OPENSSL} ecparam -genkey -name "$kSize" -out "$kAlias/$x509PKEY"
        if [ $? -ne 0 ]; then
            echo "x509KeyGen: Key generation failed" >&2
            return 1
        fi
    elif [[ $kType == "DSA" ]]; then
        if [[ -z $paramAlias ]]; then
            while true; do
                rm -f "$kAlias/dsa_params.pem"
                ${x509OPENSSL} dsaparam -out "$kAlias/dsa_params.pem" "$kSize"
                if [ $? -ne 0 ]; then
                    echo "x509KeyGen: Parameter generation failed" >&2
                    return 1
                fi
                if [[ $conservative == "False" && $incompatible == "False" ]]; then
                    break
                fi
                if [[ $conservative == "True" ]] &&
                    ${x509OPENSSL} dsaparam -noout -text -in "$kAlias/dsa_params.pem" | \
                    grep -iA1 'G:' | tail -n 1 | grep -E '^[[:space:]]*00:'; then
                    break
                fi
                if [[ $incompatible == "True" ]] &&
                    ${x509OPENSSL} dsaparam -noout -text -in "$kAlias/dsa_params.pem" |\
                    grep -iA1 'G:' | tail -n 1 | grep -E '^[[:space:]]*[1-3]'; then
                    break
                fi
            done
            dsaParams="$kAlias/dsa_params.pem"
        else
            dsaParams="$paramAlias/dsa_params.pem"
        fi

        while true; do
            ${x509OPENSSL} gendsa -out "$kAlias/$x509PKEY" "$dsaParams"
            if [ $? -ne 0 ]; then
                echo "x509KeyGen: Key generation failed" >&2
                return 1
            fi
            if [[ $conservative == "False" && $incompatible == "False" ]]; then
                break
            fi
            local prime_chars
            local pub_chars
            prime_chars="$(${x509OPENSSL} dsa -noout -text -in "$kAlias/$x509PKEY" | \
                grep -iA 100 '^P:' | grep -iB 100 '^Q:' | wc -c)"
            pub_chars="$(${x509OPENSSL} dsa -noout -text -in "$kAlias/$x509PKEY" | \
                grep -iA 100 'pub:' | grep -iB 100 '^P:' | wc -c)"
            # make sure that MSB is set
            # and that the public value is large enough
            if [[ $conservative == "True" ]] &&
                ${x509OPENSSL} dsa -noout -text -in "$kAlias/$x509PKEY" | \
                grep -A1 'pub:' | tail -n 1 | grep -E '^[[:space:]]*00:' &&
                [[ $pub_chars == $prime_chars ]]; then
                break
            fi
            if [[ $incompatible == "True" ]] &&
                ${x509OPENSSL} dsa -noout -text -in "$kAlias/$x509PKEY" | \
                grep -A1 'pub:' | tail -n 1 | grep -E '^[[:space:]]*[1-3]'; then
                break
            fi
        done
    elif [[ $kType == "RSA" ]]; then
        ${x509OPENSSL} genrsa -out "$kAlias/$x509PKEY" "$kSize"
        if [ $? -ne 0 ]; then
            echo "x509KeyGen: Key generation failed" >&2
        fi
    else # RSA-PSS, DH, GOST2001
        local options
        declare -a options
        options=("-out" "$kAlias/$x509PKEY")
        options=("${options[@]}" "-algorithm" "$kType")
        if [[ $kType == "RSA-PSS" ]]; then
            options=("${options[@]}" "-pkeyopt" "rsa_keygen_bits:$kSize")
        fi
        if [[ ${#genpkeyOpts[@]} -gt 0 ]]; then
            options=("${options[@]}" "${genpkeyOpts[@]}")
        fi
        ${x509OPENSSL} genpkey "${options[@]}"
        if [ $? -ne 0 ]; then
            echo "x509KeyGen: Key generation failed" >&2
        fi
    fi

}

true <<'=cut'
=pod

=head2 x509SelfSign()

Create a self signed certificate for a given alias.

=over 4

B<x509SelfSign>
[B<--basicKeyUsage> I<BASICKEYUSAGE>]
[B<--bcCritical>]
[B<--bcPathLen> I<LENGTH>]
[B<--caFalse>]
[B<--caTrue>]
[B<--CN> I<commonName>]
[B<--DN> I<part-of-dn>]
[B<--ncPermit> I<HOST>]
[B<--ncExclude> I<HOST>]
[B<--ncNotCritical>]
[B<--md> I<HASH>]
[B<--padding> I<PADDING>]
[B<--pssSaltLen> I<SALTLEN>]
[B<--pssMgf1Md> I<MD>]
[B<--noAuthKeyId>]
[B<--noBasicConstraints>]
[B<--noSubjKeyId>]
[B<--notAfter> I<ENDDATE>]
[B<--notBefore> I<STARTDATE>]
[B<-t> I<type>]
[B<-v> I<version>]
I<alias>

=back

=over

=item B<--basicKeyUsage> I<BASICKEYUSAGE>

Specified the value of X.509 version 3 Basic Key Usage extension.

See B<X.509 EXTENSIONS> section for avaliable values for I<BASICKEYUSAGE>.
In case the value should be marked critical, prepend the values with
C<critical,>.

Default value for role C<ca> is C<critical, keyCertSign, cRLSign>.
For role C<webserver> is
C<critical, digitalSignature, keyEncipherment, keyAgreement>.
For role C<webclient> is C<digitalSignature, keyEncipherment>.

=item B<--bcCritical>

Sets the C<critical> flag for Basic Constraints extension.

=item B<--bcPathLen> I<LENGTH>

Sets the maximum path len for certificate chain to I<LENGTH>.

Undefined (unbounded) by default.

=item B<--caFalse>

Sets the Basic Constraints flag for CA to false. Note that this unsets the
default criticality flag for Basic Constraints. To restore it, use
B<--bcCritical>.

=item B<--caTrue>

Sets the Basic Constraints flag for CA to true. Note that this unsets
the flag for criticality of Basic Constraints. To restore it, use
B<--bcCritical>.

This is the default for C<CA> role together with B<--bcCritical>

=item B<--CN> I<commonName>

Specifies the common name (CN) for distinguished name (DN) in the certificate.
This applies for both the subject name and issuer name in the generated
certificate.

If no B<--DN>'s are specified, C<localhost> will be used for I<webserver> and
C<John Smith> for I<webclient>. I<ca> role will not get a common name but
its DN will be set to C<O=Example CA>.

=item B<--DN> I<part-of-dn>

Specifies parts of distinguished name (DN) of the generated certificate.
The order will be the same as will appear in the certificate.
If the B<--CN> option is also specified then I<commonName> will be placed last.

The I<part-of-dn> is comprised of two values with C<=> in the middle.
For example: C<commonName = example.com>, C<OU=Example Unit> or C<C=US>.

Note that existence of no particular element is enforced but the DN I<must>
have at least one element. If none is specified, the defaults from B<--CN>
option will be used.

Note that the case in DN elements B<is> significant.

TODO: Insert list of known DN parts

=over

=item I<CN> | I<commonName>

Human readable name

=item I<OU> | I<organisationalUnit>

Name of company department

=item I<O> | I<organisationName>

Name of organisation or company

=item I<C> | I<countryName>

Two letter code of country

=item I<emailAddress>

RFC822 address

=item I<localityName>

City name

=item I<stateOrProvinceName>

State or province name hosting the HQ.

=back

=item B<--ncPermit> I<HOST>

Adds HOST to x509v3 nameConstraint as permitted (see RFC 5820).

HOST can be a hostname (google.com), IP address (8.8.8.8),
or something supported directly by openssl (IP:192.168.0.0/255.255.0.0,
DNS:google.com - see man x509v3_config for details).
    
=item B<--ncExclude> I<HOST>

Adds HOST to x509v3 nameConstraint as excluded (see RFC 5820).
See B<--ncPermit> for details.

=item B<--ncNotCritical>

Marks nameConstraints as NOT critical, which is against RFC 5820.
Default is critical.

=item B<--md> I<HASH>

Sets the cryptographic hash (message digest) for signing certificates.

Note that some combinations of key types and digest algorithms are unsupported.
For example, you can't sign using ECDSA and MD5.

SHA256 by default, will be updated to weakeast hash recommended by NIST or
generally thought to be secure. SHA1 in case the openssl version installed
doesn't support SHA256.

=item B<--padding> I<PADDING>

Set the specified RSA padding type for the certificate signature. Acceptable
values are B<pkcs1> (the default, for PKCS#1 v1.5 padding with DigestInfo),
B<x931> (for X 9.31 padding) and B<pss> (for RSASSA-PSS padding).

=item B<--pssSaltLen> I<SALTLEN>

Set the length of used salt (in bytes) that will be used to create the
signature. Special values are: B<-1> for setting the salt size to the size
of used message digest, B<-2> for automatically determining the size of
the salt and B<-3> for using the maximum possible salt size.

=item B<--noAuthKeyId>

Do not set the Authority Key Identifier extension in the certificate.

=item B<--noBasicConstraints>

Remove Basic Constraints extension from the certificate completely.
Note that in PKIX certificate validation, V3 certificate with no Basic
Constraints will I<not> be considered to be a CA.

=item B<--noSubjKeyId>

Do not set the Subject Key Identifier extension in the certificate.
Implies B<--noAuthKeyId>.

=item B<--notAfter> I<ENDDATE>

Sets the date after which the certificate won't be valid.
Uses date(1) for conversion so values like "1 year" (from now), "2 years ago",
"3 months", "4 weeks ago", "2 days ago", etc. work just as well as values
like "201001011235Z".
Use C<date -d I<ENDDATE>> to verify if it represent the date you want.

By default C<10 years> for I<ca> role, C<1 year> for all others.

=item B<--notBefore> I<STARTDATE>

Sets the date since which the certificate is valid. Uses date(1) for conversion
so values like "1 year" (from now), "2 years ago", "3 months", "4 weeks ago",
"2 days ago", etc. work just as well as values like "201001011235Z".
Use C<date -d I<STARTDATE>> to verify if it represents the date you want.

By default C<5 years ago> for I<ca> role, C<now> for all others.

=item B<-t> I<type>

Sets the general type of certificate: C<CA>, C<webserver>, C<webclient> or
C<none>.
In case there are no additional options, this also sets correct values
for basic key usage and extended key usage for given role.
The special value of C<none> removes use of basic key usage and extended key
usage extensions.

Note that while the names indicate "web", they actually apply for all servers
and clients that use TLS or SSL and in case of C<webclient> also for S/MIME.

C<CA> by default.

=item B<-v> I<version>

Version of the certificate to create, accepted versions are C<1> and C<3>.
Unfortunately, creating version C<1> certificate with extensions is impossible
with current openssl so the script detects that and returns error.

Version C<3> by default.

=item I<alias>

Name of directory in which the generated certificate will be placed
and where the private key used for signing is located.
The certificate will be placed in file named F<cert.pem> if I<x509CERT>
variable was not changed.

=back

Returns 0 if signing was successfull, non zero otherwise.

=cut

x509SelfSign() {
    # name of key to process
    local kAlias
    # version of cert to generate
    local certV=3
    # role for certificate
    local certRole="CA"
    # common name of certificate
    local certCN
    # parts of DN (array)
    declare -a certDN
    # date since which the cert is valid
    local notBefore=""
    # date until which the cert is valid
    local notAfter=""
    # value for Basic Key Usage Extension
    local basicKeyUsage=""
    # set the value for CA bit for Basic Constraints
    local basicConstraints=""
    # set the length for pathlen in Basic Constraints
    local bcPathLen=""
    # set the criticality flag for Basic Constraints
    local bcCritical=""
    # permitted names as per RFC-5280
    local -a namesPermitted
    # excluded names as per RFC-5280
    local -a namesExcluded
    # flag set when name constraints are not to be marked critical
    local ncCritical="critical,"
    # set the message digest algorithm used for signing
    local certMD=""
    # set the padding mode used for signature
    local sigPad=""
    # set the length of salt used in RSA-PSS signatures
    local pssSaltLen=""
    # flag set when the Authority Key Identifier is not supposed to be
    # added to certificate
    local noAuthKeyId=""
    # flag set when the Subject Key Identifier is not supposed to be added
    # to certificate
    local noSubjKeyId=""

    #
    # parse options
    #

    local TEMP=$(getopt -o t:v: -l CN: -l DN: -l notAfter: -l notBefore: \
        -l basicKeyUsage: \
        -l caTrue \
        -l caFalse \
        -l noBasicConstraints \
        -l ncPermit: \
        -l ncExclude: \
        -l ncNotCritical \
        -l bcPathLen: \
        -l bcCritical \
        -l noAuthKeyId \
        -l noSubjKeyId \
        -l md: \
        -l padding: \
        -l pssSaltLen: \
        -n x509SelfSign -- "$@")
    if [ $? -ne 0 ]; then
        echo "X509SelfSign: can't parse options" >&2
        return 1
    fi

    eval set -- "$TEMP"

    while true ; do
        case "$1" in
            -t) certRole="$2"; shift 2
                ;;
            -v) certV="$2"; shift 2
                ;;
            --CN) certCN="$2"; shift 2
                ;;
            --DN) certDN=("${certDN[@]}" "$2"); shift 2
                ;;
            --notAfter) notAfter="$2"; shift 2
                ;;
            --notBefore) notBefore="$2"; shift 2
                ;;
            --basicKeyUsage) basicKeyUsage="$2"; shift 2
                ;;
            --caTrue) basicConstraints="CA:TRUE"; shift 1
                ;;
            --caFalse) basicConstraints="CA:FALSE"; shift 1
                ;;
            --noBasicConstraints) basicConstraints="undefined"; shift 1
                ;;
            --bcPathLen) bcPathLen="$2"; shift 2
                ;;
            --bcCritical) bcCritical="true"; shift 1
                ;;
            --ncPermit) namesPermitted=("${namesPermitted[@]}" "$2"); shift 2
                ;;
            --ncExclude) namesExcluded=("${namesExcluded[@]}" "$2"); shift 2
                ;;
            --ncNotCritical) ncCritical=""; shift 1
                ;;
            --md) certMD="$2"; shift 2
                ;;
            --padding) sigPad="$2"; shift 2
                ;;
            --pssSaltLen) pssSaltLen="$2"; shift 2
                ;;
            --noAuthKeyId) noAuthKeyId="true"; shift 1
                ;;
            --noSubjKeyId) noSubjKeyId="true"; shift 1
                ;;
            --) shift 1
                break
                ;;
            *) echo "x509SelfSign: Unknown option: '$1'" >&2
                return 1
        esac
    done

    kAlias="$1"

    #
    # sanity check options
    #

    if [ ! -d "$kAlias" ] || [ ! -e "$kAlias/$x509PKEY" ]; then
        echo "x509SelfSign: private key '$kAlias' has not yet been generated"\
            >&2
        return 1
    fi

    if [[ "$sigPad" && "$sigPad" != "pss" && "$pssSaltLen" ]] \
        || [[ -z "$sigPad" && "$pssSaltLen" ]]; then

        echo "x509SelfSign: pssSaltLen is only applicable to pss padding" >&2
        return 1
    fi

    certRole=$(tr '[:upper:]' '[:lower:]' <<< ${certRole})
    if [[ $certRole != "ca" ]] && [[ $certRole != "webserver" ]] \
        && [[ $certRole != "webclient" ]] && [[ $certRole != "none" ]]; then

        echo "x509SelfSign: Unknown role: '$certRole'" >&2
        return 1
    fi

    if [[ $certV != 1 ]] && [[ $certV != 3 ]]; then
        echo "x509SelfSign: Certificate version must be 1 or 3" >&2
        return 1
    fi

    if [[ $certV == 1 ]]; then
        if [[ ! -z $basicKeyUsage ]]; then
            echo "x509SelfSign: Can't create version 1 certificate with "\
                "extensions" >&2
            return 1
        fi
    fi

    if [ ! -z "$certCN" ]; then
        certDN=("${certDN[@]}" "CN = $certCN")
    fi

    if [ ${#certDN[@]} -eq 0 ]; then
        case $certRole in
            ca) certDN=("${certDN[@]}" "O = Example CA")
                ;;
            webserver) certDN=("${certDN[@]}" "CN = localhost")
                ;;
            webclient) certDN=("${certDN[@]}" "CN = John Smith")
                ;;
            none) certDN=("${certDN[@]}" "O = Unknown use cert")
                ;;
            *) echo "x509SelfSign: Unknown cert role: $certRole" >&2
                return 1
                ;;
        esac
    fi

    if [[ -z $notAfter ]] && [[ $certRole == "ca" ]]; then
        notAfter="10 years"
    fi # default of "1 year" is in config generator

    if [[ -z $notBefore ]] && [[ $certRole == "ca" ]]; then
        notBefore="5 years ago"
    fi # dafault of "now" is in config generator

    if [[ ! -z $bcPathLen ]]; then
        if [[ $basicConstraints == "undefined" ]] ||
            [[ $basicConstraints == "CA:FALSE" ]]; then
            echo "x509SelfSign: Path len can be specified only with caTrue "\
                "option" >&2
            return 1
        fi
        if [[ $certRole != "ca" ]] && [[ -z $basicConstraints ]]; then
            echo "x509SelfSign: Only ca role uses CA:TRUE constraint, use "\
                "--caTrue to override" >&2
            return 1;
        fi
    fi

    if [[ -z $basicConstraints ]]; then
        case $certRole in
            ca) basicConstraints="CA:TRUE"
                bcCritical="true"
                ;;
            *) basicConstraints="CA:FALSE"
                bcCritical="true"
                ;;
        esac
    fi

    local basicConstraintsOption=""
    if [[ $bcCritical == "true" ]]; then
        basicConstraintsOption="critical, "
    fi
    if [[ $basicConstraints == "undefined" ]]; then
        basicConstraintsOption=""
    else
        basicConstraintsOption="${basicConstraintsOption}${basicConstraints}"
        if [[ ! -z $bcPathLen ]]; then
            basicConstraintsOption="${basicConstraintsOption}, pathlen: ${bcPathLen}"
        fi
    fi

    if [[ -z $basicKeyUsage ]]; then
        case $certRole in
            ca) basicKeyUsage="critical, keyCertSign, cRLSign"
                ;;
            webserver) basicKeyUsage="critical, digitalSignature, "
                basicKeyUsage="${basicKeyUsage}keyEncipherment, keyAgreement"
                ;;
            webclient) basicKeyUsage="digitalSignature, keyEncipherment"
                ;;
            none)
                ;;
            *) echo "x509SelfSign: Unknown cert role: $certRole" >&2
                return 1
                ;;
        esac
    fi

    if [[ $noSubjKeyId == "true" ]]; then
        noAuthKeyId="true"
    fi

    #
    # prepare configuration file for signing
    #

    declare -a parameters
    for option in "${certDN[@]}"; do
        parameters=("${parameters[@]}" "--dn=$option")
    done

    if [[ ! -z $notAfter ]]; then
        parameters=("${parameters[@]}" "--notAfter=$notAfter")
    fi
    if [[ ! -z $notBefore ]]; then
        parameters=("${parameters[@]}" "--notBefore=$notBefore")
    fi

    if [[ ! -z $basicConstraintsOption ]]; then
        parameters=("${parameters[@]}" "--basicConstraints=$basicConstraintsOption")
    fi

    if [[ ! -z $basicKeyUsage ]]; then
        parameters=("${parameters[@]}" "--basicKeyUsage=$basicKeyUsage")
    fi

    local nameConstraints="$(__INTERNAL_x509NamesToNCs namesPermitted[@] permitted)"
    local joinedNamesExcluded="$(__INTERNAL_x509NamesToNCs namesExcluded[@] excluded)"
    if [[ ! -z $nameConstraints && ! -z $joinedNamesExcluded ]]; then
        nameConstraints="${nameConstraints},${joinedNamesExcluded}"
    else
        nameConstraints="${nameConstraints}${joinedNamesExcluded}"
    fi
    if [[ ! -z $nameConstraints ]]; then
        parameters=("${parameters[@]}" "--x509v3Extension=nameConstraints=$ncCritical$nameConstraints")
    fi

    if [[ -n $certMD ]]; then
        parameters=("${parameters[@]}" "--md=$certMD")
    fi

    if [[ $noSubjKeyId != "true" ]]; then
        parameters=("${parameters[@]}" "--subjectKeyIdentifier")
    fi

    __INTERNAL_x509GenConfig "${parameters[@]}" "$kAlias"
    if [ $? -ne 0 ]; then
        return 1
    fi

    #
    # create self signed certificate
    #
    declare -a options=()
    if [[ ! -z $sigPad ]]; then
        options=("${options[@]}" "-sigopt" "rsa_padding_mode:$sigPad")
    fi
    if [[ ! -z $pssSaltLen ]]; then
        options=("${options[@]}" "-sigopt" "rsa_pss_saltlen:$pssSaltLen")
    fi

    # because we want to have full control over certificate fields
    # (like notBefore and notAfter) we have to create the certificate twice

    # create dummy self signed certificate
    ${x509OPENSSL} req -x509 -new -key $kAlias/$x509PKEY \
        -out $kAlias/temp-$x509CERT \
        -batch -config $kAlias/$x509CACNF "${options[@]}"
    if [ $? -ne 0 ]; then
        echo "x509SelfSign: temporary certificate generation failed" >&2
        return 1
    fi

    # create CSR for signing by the dummy certificate
    ${x509OPENSSL} x509 -x509toreq -signkey $kAlias/$x509PKEY \
        -out $kAlias/$x509CSR \
        -in $kAlias/temp-$x509CERT
    if [ $? -ne 0 ]; then
        echo "x509SelfSign: certificate signing request failed" >&2
        return 1
    fi

    declare -a caOptions
    caOptions=("${caOptions[@]}" "-preserveDN")
    if [[ $certV == "3" ]]; then
        caOptions=("${caOptions[@]}" "-extensions" "v3_ext")
    fi
    if [[ ! -z "$sigPad" ]]; then
        caOptions=("${caOptions[@]}" "-sigopt" "rsa_padding_mode:$sigPad")
    fi
    if [[ ! -z "$pssSaltLen" ]]; then
        caOptions=("${caOptions[@]}" "-sigopt" "rsa_pss_saltlen:$pssSaltLen")
    fi
    # the serial number must be the same, so reset index and serial number
    rm -f "$kAlias/$x509CAINDEX" "$kAlias/$x509CASERIAL"
    touch "$kAlias/$x509CAINDEX"
    echo 01 > "$kAlias/$x509CASERIAL"

    # sign the certificate using the full CA functionality to get proper
    # key id and subject key identifier
    ${x509OPENSSL} ca -config $kAlias/$x509CACNF -batch \
        -keyfile $kAlias/$x509PKEY \
        -cert $kAlias/temp-$x509CERT -in $kAlias/$x509CSR \
        -out $kAlias/$x509CERT "${caOptions[@]}"
    if [ $? -ne 0 ]; then
        echo "x509SelfSign: signing the certificate failed" >&2
        return 1
    fi

    mv -f "$kAlias/$x509CERT" "$kAlias/temp-$x509CERT"

    # now we have a certificate with proper serial number, it's just missing
    # Authority Key Identifier that references it, so we sign itself for the
    # third time
    if [[ $noAuthKeyId != "true" ]]; then
        parameters=("${parameters[@]}" "--authorityKeyIdentifier=keyid,issuer")
    fi
    # the serial number must be the same, so reset index and serial number
    rm -f "$kAlias/$x509CAINDEX" "$kAlias/$x509CASERIAL"
    __INTERNAL_x509GenConfig "${parameters[@]}" "$kAlias"
    if [ $? -ne 0 ]; then
        return 1
    fi

    ${x509OPENSSL} ca -config $kAlias/$x509CACNF -batch \
        -keyfile $kAlias/$x509PKEY \
        -cert $kAlias/temp-$x509CERT -in $kAlias/$x509CSR \
        -out $kAlias/$x509CERT "${caOptions[@]}"

    if [ $? -ne 0 ]; then
        echo "x509SelfSign: signing the certificate failed" >&2
        return 1
    fi
}

true <<'=cut'
=pod

=head2 x509KeyCopy()

Create a new key by copying the key material from a different certificate/key.

=over 4

B<x509KeyCopy>
B<-t> I<target>
I<alias>

=back

Uses the key from I<alias> to create a directory I<target> with the same key.

Returns non zero if I<target> exists or I<alias> doesn't exist or doesn't
contain private key.

=cut

x509KeyCopy() {

    # destination of copy
    local newKey=""
    # source of key
    local kAlias=""

    local TEMP=$(getopt -o t: -n x509KeyCopy -- "$@")
    if [ $? -ne 0 ]; then
        echo "X509KeyCopy: Can't parse options" >&2
        return 1
    fi

    eval set -- "$TEMP"

    while true ; do
        case "$1" in
            -t) newKey="$2"; shift 2
                ;;
            --) shift 1
                break
                ;;
            *) echo "x509KeyCopy: Unknown option: $1" >&2
                return 1
        esac
    done

    kAlias="$1"

    if [ ! -e "$kAlias/$x509PKEY" ]; then
        echo "x509KeyCopy: Source invalid" >&2
        return 1
    fi

    if [ -e "$newKey" ]; then
        echo "x509KeyCopy: Destination exists" >&2
        return 1
    fi

    mkdir "$newKey"
    if [ $? -ne 0 ]; then
        echo "x509KeyCopy: Can't create directory for new key" >&2
        return 1
    fi

    cp "$kAlias/$x509PKEY" "$newKey"
    if [ $? -ne 0 ]; then
        echo "x509KeyCopy: Can't copy key" >&2
        return 1
    fi

    return 0
}

true <<'=cut'
=pod

=head2 x509CertSign()

Create a certificate signed by a given alias.

=over 4

B<x509CertSign>
[B<--basicKeyUsage> I<BASICKEYUSAGE>]
[B<--bcCritical>]
[B<--bcPathLen> I<PATHLEN>]
[B<--caFalse>]
[B<--caTrue>]
[B<--DN> I<DNPART>]
[B<--extendedKeyUsage> I<EKU>]
[B<--ncPermit> I<HOST>]
[B<--ncExclude> I<HOST>]
[B<--ncNotCritical>]
[B<--md> I<HASHNAME>]
[B<--padding> I<PADDING>]
[B<--pssSaltLen> I<SALTLEN>]
[B<--noBasicConstraints>]
[B<--notAfter> I<ENDDATE>]
[B<--notBefore> I<STARTDATE>]
[B<--ocspNoCheck>[=I<CRITICAL>]]
[B<--ocspResponderURI> I<URI>]
[B<--subjectAltName> I<ALTNAME>]
[B<--subjectAltNameCritical>]
[B<-t> I<TYPE>]
[B<-v> I<version>]
B<--CA> I<CAAlias>
I<alias>

=back

=over

=item B<--basicKeyUsage> I<BASICKEYUSAGE>

Specify the settings for basic key usage extension.
See B<X.509 EXTENSIONS> section for list of available keywords.

Default "critical, keyCertSign, cRLSign" for C<CA> role,
"critical, digitalSignature, keyEncipherment, keyAgreement" for C<webserver>
role and "digitalSignature, keyEncipherment" for C<webclient> role.

=item B<--bcCritical>

Sets the C<critical> flag for Basic Constraints extension.
See B<X.509 EXTENSIONS> section to see what it means.

=item B<--bcPathLen> I<PATHLEN>

Sets the maximum path len for certificate chain to I<PATHLEN>.

Undefined (unbounded) by default.

=item B<--CA> I<CAAlias>

Name the key and certificate used for signing the new certificate.

The CA specified by I<CAAlias> must have its key generated and certificate
present (either through self signing or through previous certificate
signing operation).

=item B<--caFalse>

Sets the Basic Constraints flag for CA to false. Note that his unsets the
default criticality flag for Basic Constraints. To restore it, use
B<--bcCritical>.

This is the default for C<webserver> and C<webclient> roles.

=item B<--caTrue>

Sets the Basic Constraints flag for CA to true. Note that this unsets
the default flag for criticality of Basic Constraints. To restore it, use
B<--bcCritical>.

This is the default for C<CA> role.

=item B<--DN> I<DNPART>

Specifies parts of distinguished name (DN) of the generated certificate.
The order in which they are provided will be used for certificate generation.

See the same option description for I<x509SelfSign> for available I<DNPART>
options.

By default C<O = Example intermediate CA> for C<CA> role, C<CN = localhost>
for C<webserver> role and C<CN = John Smith> for C<webclient> role.

=item B<--extendedKeyUsage> I<EKU>

Add the Extended Key Usage extension to the certificate. I<EKU> is a comma
separated list of key usages. Both literal OIDs and names can be used.

Define as empty string to remove the default value. Prepend C<critical,> before
usage names to mark the extension as critical.

Valid names are:

=over

=item I<serverAuth>

SSL/TLS Server authentication

=item I<clientAuth>

SSL/TLS Client authentication

=item I<codeSigning>

Executable code signing

=item I<emailProtection>

Signing and encrypting S/MIME messages.

=item I<timeStamping>

Signing of trusted timestamps (required for Time Stamping Authority),
many implementations require this use to be only one and marked as critical
for the TSA to be considered valid.

=item I<msCodeInd>

Microsoft Individual Code Signing (authnticode)

=item I<msCodeCom>

Microsoft Commercial Code Signing (authenticode)

=item I<msCTLSign>

Microsoft Trust List signing

=item I<msSGC>

Microsoft Server Gated Cryptography

=item I<msEFS>

Microsoft Encrypted File System

=item I<nsSGC>

Netscape Server Gated Crypto

=item I<ocspSigning>

Allow the server to sign OCSP responses, also known as id_kp_OCSPSigning.

=item I<ipsecEndSystem>

Certificate can be used as the End System in IPsec

=item I<ipsecTunnel>

Certificate can be used in IPsec tunnels.

=item I<ipsecUser>

Certificate can be used by user (client).

=item I<DVCS>

Certificate can be used as a Data Validation and Certification Server (a trusted
third party).

=back

By default undefined for C<CA> role, I<serverAuth> for C<webserver> role and
I<clientAuth,emailProtection> for C<webclient>.

=item B<--ncPermit> I<HOST>

Adds HOST to x509v3 nameConstraint as permitted (see RFC 5820).

HOST can be a hostname (google.com), IP address (8.8.8.8),
or something supported directly by openssl (IP:192.168.0.0/255.255.0.0,
DNS:google.com - see man x509v3_config for details).
    
=item B<--ncExclude> I<HOST>

Adds HOST to x509v3 nameConstraint as excluded (see RFC 5820).
See B<--ncPermit> for details.

=item B<--ncNotCritical>

Marks nameConstraints as NOT critical, which is against RFC 5820.
Default is critical.

=item B<--md> I<HASHNAME>

Sets the cryptographic hash (message digest) for signing certificates.

Note that some combinations of key types and digest algorithms are unsupported.
For example, you can't sign using ECDSA and MD5.

SHA256 by default, will be updated to weakeast hash recommended by NIST or
generally thought to be secure.

=item B<--padding> I<PADDING>

Set the specified RSA padding type for the certificate signature. Acceptable
values are B<pkcs1> (the default, for PKCS#1 v1.5 padding with DigestInfo),
B<x931> (for X 9.31 padding) and B<pss> (for RSASSA-PSS padding).

=item B<--pssSaltLen> I<SALTLEN>

Set the length of used salt (in bytes) that will be used to create the
signature. Special values are: B<-1> for setting the salt size to the size
of used message digest, B<-2> for automatically determining the size of
the salt and B<-3> for using the maximum possible salt size.

=item B<--pssMgf1Md> I<MD>

Set the hash used for the MGF1 inside RSA-PSS signatures.
By default it's the same value that is used for B<--md> option.

=item B<--noAuthKeyId>

Do not add the Authority Key Identifier extension to generated certificates.

=item B<--noBasicConstraints>

Remove Basic Constraints extension from the certificate completely.
Note that in PKIX certificate validation, V3 certificate with no Basic
Constraints will I<not> be considered to be a CA.

=item B<--noSubjKeyId>

Do not add the Subject Key Identifier extension to generated certificates.

=item B<--notAfter> I<ENDDATE>

Sets the date after which the certificate won't be valid.
Uses date(1) for conversion so values like "1 year" (from now), "2 years ago",
"3 months", "4 weeks ago", "2 days ago", etc. work just as well as values
like "201001011235Z".
Use C<date -d I<ENDDATE>> to verify if it represent the date you want.

By default C<10 years> for I<ca> role, C<1 year> for all others.

=item B<--notBefore> I<STARTDATE>

Sets the date since which the certificate is valid. Uses date(1) for conversion
so values like "1 year" (from now), "2 years ago", "3 months", "4 weeks ago",
"2 days ago", etc. work just as well as values like "201001011235Z".
Use C<date -d I<STARTDATE>> to verify if it represents the date you want.

By default C<5 years ago> for I<ca> role, C<now> for all others.

=item B<--ocspNoCheck>[=I<CRITICAL>]

Add the OCSP No Check extension to certificate, also known as
id-pkix-ocsp-nocheck.

I<CRITICAL> is the optional argument that, if provided (with any value, though
C<critical> is recommended), will mark the extension as critical.

=item B<--ocspResponderURI> I<URI>

Add Authority Info Access extension that specifies location of the OCSP
responder fo this certificate. The URI must be specified with protocol.

For example:

    http://ocsp.example.com/

=item B<--subjectAltName> I<ALTNAME>

Specify the Subject Alternative Name extension items to add. The format is
similar to the B<DN>, first the literal added, then equals sign (=) and
finally the value added.

The literals supported are:

=over

=item I<email>

Email address in the form:

    username@domainname

=item I<URI>

Full Uniform Resource Identifier, with protocol, host name and location.

=item I<DNS>

DNS host name

=item I<IP>

An IP Address, both IPv4 and IPv6 is supported

=back

Note that if you want multiple literals of the same type, you need to specify
the order in which they will be placed by appending position after a dot:

    DNS.1=example.com
    DNS.2=www.example.com

=item B<--subjectAltNameCritical>

Mark the Subject Alternative Name as critical.

=item B<-t> I<TYPE>

Sets the general type of certificate: C<CA>, C<webserver>, C<webclient> or
C<none>.
In case there are no additional options, this also sets correct values
for basic key usage and extended key usage for given role.
For case of C<none> the default is to not add basic key usage or extended
key usage extensions to the certificate.

Note that while the names indicate "web", they actually apply for all servers
and clients that use TLS or SSL and in case of C<webclient> also for S/MIME.

C<webserver> by default.

=item B<-v> I<version>

Version of the certificate to create, accepted versions are C<1> and C<3>.
Unfortunately, creating version C<1> certificate with extensions is impossible
with current openssl so the script detects that and returns error.

Version C<3> by default.

=item I<alias>

Location of the private key for signing.

Note that the private key must have been already generated.

=back

Return 0 if signing was successfull, non zero otherwise.

=cut

x509CertSign() {
    # alias of the key to be signed
    local kAlias
    # alias of the CA key and cert to be used for signing
    local caAlias
    # X.509 certificate version (1 or 3)
    local certV="3"
    # role of certificate
    local certRole="webserver"
    # date since which the cert is valid
    # default is in config generator (now)
    local notBefore=""
    # date until which the cert is valid
    # default is in config generator (1 year)
    local notAfter=""
    # set the value for CA bit for Basic Constraints
    local basicConstraints=""
    # set the length for pathlen in Basic Constraints
    local bcPathLen=""
    # set the criticality flag for Basic Constraints
    local bcCritical=""
    # permitted names as per RFC-5280
    local -a namesPermitted
    # excluded names as per RFC-5280
    local -a namesExcluded
    # flag set when name constraints are not to be marked critical
    local ncCritical="critical,"
    # set the message digest used for signing the certificate
    # default is in config generator (sha256)
    local certMD=""
    # set the RSA signature padding mode
    local sigPad=""
    # set the length of the salt used with RSA-PSS signatures
    local pssSaltLen=""
    # set the mgf1 message digest for RSA-PSS signatures
    local pssMgf1Md=""
    # sets the Basic Key Usage
    local basicKeyUsage=""
    # distinguished name of the signed certificate
    declare -a certDN
    # Subject Alternative Name of the signed certificate
    declare -a subjectAltName
    # flag set when Subject Alternative Name is to be marked critical
    local subjectAltNameCritical=""
    # location of OCSP responder for the CA that issued this certificate
    local ocspResponderURI=""
    # value for the Extended Key Usage extension
    local extendedKeyUsage=""
    # flag to set the ocsp nocheck extension
    local ocspNoCheck=""
    # flag to remove Authority Key Identifier extension from certificate
    local noAuthKeyId=""
    # flag to remove Subject Key Identifier extension from certificate
    local noSubjKeyId=""

    #
    # parse options
    #

    local TEMP=$(getopt -o v:t: -l CA: \
        -l DN: \
        -l notAfter: \
        -l notBefore: \
        -l caTrue \
        -l caFalse \
        -l noBasicConstraints \
        -l bcPathLen: \
        -l bcCritical \
        -l ncPermit: \
        -l ncExclude: \
        -l ncNotCritical \
        -l basicKeyUsage: \
        -l md: \
        -l padding: \
        -l pssSaltLen: \
        -l pssMgf1Md: \
        -l subjectAltName: \
        -l subjectAltNameCritical \
        -l ocspResponderURI: \
        -l extendedKeyUsage: \
        -l ocspNoCheck:: \
        -l noAuthKeyId \
        -l noSubjKeyId \
        -n x509CertSign -- "$@")
    if [ $? -ne 0 ]; then
        echo "x509CertSign: can't parse options" >&2
        return 1
    fi

    eval set -- "$TEMP"

    while true ; do
        case "$1" in
            -v) certV="$2"; shift 2
                ;;
            -t) certRole="$2"; shift 2
                ;;
            --CA) caAlias="$2"; shift 2
                ;;
            --DN) certDN=("${certDN[@]}" "$2"); shift 2
                ;;
            --notAfter) notAfter="$2"; shift 2
                ;;
            --notBefore) notBefore="$2"; shift 2
                ;;
            --caTrue) basicConstraints="CA:TRUE"; shift 1
                ;;
            --caFalse) basicConstraints="CA:FALSE"; shift 1
                ;;
            --noBasicConstraints) basicConstraints="undefined"; shift 1
                ;;
            --bcPathLen) bcPathLen="$2"; shift 2
                ;;
            --bcCritical) bcCritical="true"; shift 1
                ;;
            --basicKeyUsage) basicKeyUsage="$2"; shift 2
                ;;
            --ncPermit) namesPermitted=("${namesPermitted[@]}" "$2"); shift 2
                ;;
            --ncExclude) namesExcluded=("${namesExcluded[@]}" "$2"); shift 2
                ;;
            --ncNotCritical) ncCritical=""; shift 1
                ;;
            --md) certMD="$2"; shift 2
                ;;
            --padding) sigPad="$2"; shift 2
                ;;
            --pssSaltLen) pssSaltLen="$2"; shift 2
                ;;
            --pssMgf1Md) pssMgf1Md="$2"; shift 2
                ;;
            --subjectAltName) subjectAltName=("${subjectAltName[@]}" "$2"); shift 2
                ;;
            --subjectAltNameCritical) subjectAltNameCritical="true"; shift 1
                ;;
            --ocspResponderURI) ocspResponderURI="$2"; shift 2
                ;;
            --extendedKeyUsage) extendedKeyUsage="$2"; shift 2
                ;;
            --ocspNoCheck) if [[ -z $2 ]]; then
                    ocspNoCheck="true"
                else
                    ocspNoCheck="critical"
                fi
                shift 2
                ;;
            --noAuthKeyId) noAuthKeyId="true"; shift 1
                ;;
            --noSubjKeyId) noSubjKeyId="true"; shift 1
                ;;
            --) shift 1
                break
                ;;
            *) echo "x509CertSign: Unknown option: $1" >&2
                return 1
        esac
    done

    kAlias="$1"

    #
    # sanity check options
    #

    if [ ! -e "$kAlias/$x509PKEY" ]; then
        echo "x509CertSign: Private key to be signed does not exist" >&2
        return 1
    fi

    if [ ! -e "$caAlias/$x509PKEY" ]; then
        echo "x509CertSign: CA private key does not exist" >&2
        return 1
    fi

    if [ ! -e "$caAlias/$x509CERT" ]; then
        echo "x509CertSign: CA certificate does not exist" >&2
        return 1
    fi

    if [[ $certV != "1" ]] && [[ $certV != "3" ]]; then
        echo "x509CertSign: Only version 1 and 3 certificates are supported" \
            >&2
        return 1
    fi

    certRole=$(tr '[:upper:]' '[:lower:]' <<< ${certRole})
    if [[ $certRole != "ca" ]] && [[ $certRole != "webserver" ]] \
        && [[ $certRole != "webclient" ]] && [[ $certRole != "none" ]]; then

        echo "x509SelfSign: Unknown role: '$certRole'" >&2
        return 1
    fi

    if [ ${#certDN[@]} -eq 0 ]; then
        case $certRole in
            ca) certDN=("${certDN[@]}" "O = Example intermediate CA")
                ;;
            webserver) certDN=("${certDN[@]}" "CN = localhost")
                ;;
            webclient) certDN=("${certDN[@]}" "CN = John Smith")
                ;;
            none) certDN=("${certDN[@]}" "O = No role cert")
                ;;
            *) echo "x509CertSign: Unknown cert role: $certRole" >&2
                return 1
                ;;
        esac
    fi

    if [[ "$sigPad" && "$sigPad" != "pss" && "$pssSaltLen" ]] \
        || [[ -z "$sigPad" && "$pssSaltLen" ]]; then

        echo "x509CertSign: pssSaltLen is only applicable to pss padding" >&2
        return 1
    fi
    if [[ "$sigPad" && "$sigPad" != "pss" && "$pssMgf1Md" ]] \
        || [[ -z "$sigPad" && "$pssMgf1Md" ]]; then

        echo "x509CertSign: pssMgf1Md is only applicable to pss padding" >&2
        return 1
    fi

    if [[ -z $notAfter ]] && [[ $certRole == "ca" ]]; then
        notAfter="10 years"
    fi # default of "1 year" for other roles is in config generator

    if [[ -z $notBefore ]] && [[ $certRole == "ca" ]]; then
        notBefore="5 years ago"
    fi # default of "now" for other roles is in config generator

    if [[ ! -z $bcPathLen ]]; then
        if [[ $basicConstraints == "undefined" ]] ||
            [[ $basicConstraints == "CA:FALSE" ]]; then
            echo "x509SelfSign: Path len can be specified only with caTrue "\
                "option" >&2
            return 1
        fi
        if [[ $certRole != "ca" ]] && [[ -z $basicConstraints ]]; then
            echo "x509SelfSign: Only ca role uses CA:TRUE constraint, use "\
                "--caTrue to override" >&2
            return 1;
        fi
    fi

    if [[ -z $basicConstraints ]]; then
        case $certRole in
            ca) basicConstraints="CA:TRUE"
                bcCritical="true"
                ;;
                # for other usages, the recommendation is to not define it at
                # all
        esac
    fi

    local basicConstraintsOption=""
    if [[ $bcCritical == "true" ]]; then
        basicConstraintsOption="critical, "
    fi
    if [[ $basicConstraints == "undefined" ]]; then
        basicConstraintsOption=""
    else
        basicConstraintsOption="${basicConstraintsOption}${basicConstraints}"
        if [[ ! -z $bcPathLen ]]; then
            basicConstraintsOption="${basicConstraintsOption}, pathlen: ${bcPathLen}"
        fi
    fi

    if [[ -z $basicKeyUsage ]]; then
        case $certRole in
            ca) basicKeyUsage="critical, keyCertSign, cRLSign"
                ;;
            webserver) basicKeyUsage="critical, digitalSignature, "
                basicKeyUsage="${basicKeyUsage}keyEncipherment, keyAgreement"
                ;;
            webclient) basicKeyUsage="digitalSignature, keyEncipherment"
                ;;
            none)
                ;;
            *) echo "x509SelfSign: Unknown cert role: $certRole" >&2
                return 1
                ;;
        esac
    fi

    if [[ -z $extendedKeyUsage ]]; then
        case $certRole in
            webserver) extendedKeyUsage="serverAuth"
                ;;
            webclient) extendedKeyUsage="clientAuth,emailProtection"
                ;;
        esac
    fi

    #
    # prepare configuration file for signing
    #

    declare -a parameters
    for option in "${certDN[@]}"; do
        parameters=("${parameters[@]}" "--dn=$option")
    done

    if [[ ! -z $notAfter ]]; then
        parameters=("${parameters[@]}" "--notAfter=$notAfter")
    fi
    if [[ ! -z $notBefore ]]; then
        parameters=("${parameters[@]}" "--notBefore=$notBefore")
    fi

    if [[ ! -z $basicConstraintsOption ]]; then
        parameters=("${parameters[@]}" "--basicConstraints=$basicConstraintsOption")
    fi

    if [[ ! -z $basicKeyUsage ]]; then
        parameters=("${parameters[@]}" "--basicKeyUsage=$basicKeyUsage")
    fi

    local nameConstraints="$(__INTERNAL_x509NamesToNCs namesPermitted[@] permitted)"
    local joinedNamesExcluded="$(__INTERNAL_x509NamesToNCs namesExcluded[@] excluded)"
    if [[ ! -z $nameConstraints && ! -z $joinedNamesExcluded ]]; then
        nameConstraints="${nameConstraints},${joinedNamesExcluded}"
    else
        nameConstraints="${nameConstraints}${joinedNamesExcluded}"
    fi
    if [[ ! -z $nameConstraints ]]; then
        parameters=("${parameters[@]}" "--x509v3Extension=nameConstraints=$ncCritical$nameConstraints")
    fi

    if [[ -n $certMD ]]; then
        parameters=("${parameters[@]}" "--md=$certMD")
    fi

    for name in "${subjectAltName[@]}"; do
        parameters=("${parameters[@]}" "--subjectAltName=$name")
    done

    if [[ $subjectAltNameCritical == "true" ]]; then
        parameters=("${parameters[@]}" "--subjectAltNameCritical")
    fi

    if [[ ! -z $ocspResponderURI ]]; then
        parameters=("${parameters[@]}" "--authorityInfoAccess=OCSP;URI:${ocspResponderURI}")
    fi

    if [[ ! -z $extendedKeyUsage ]]; then
        parameters=("${parameters[@]}" "--extendedKeyUsage=$extendedKeyUsage")
    fi

    # DER:05:00 is a DER encoding of NULL (empty)
    if [[ $ocspNoCheck == "true" ]]; then
        parameters=("${parameters[@]}" "--x509v3Extension=noCheck=DER:05:00")
    fi
    if [[ $ocspNoCheck == "critical" ]]; then
        parameters=("${parameters[@]}" "--x509v3Extension=noCheck=critical,DER:05:00")
    fi

    if [[ $noSubjKeyId != "true" ]]; then
        parameters=("${parameters[@]}" "--subjectKeyIdentifier")
    fi

    if [[ $noAuthKeyId != "true" ]]; then
        parameters=("${parameters[@]}" "--authorityKeyIdentifier=keyid,issuer")
    fi

    __INTERNAL_x509GenConfig "${parameters[@]}" "$caAlias"
    if [ $? -ne 0 ]; then
        return 1
    fi

    #
    # create the certificate
    #

    ${x509OPENSSL} req -new -batch -key "$kAlias/$x509PKEY" \
        -out "$kAlias/$x509CSR" \
        -config "$caAlias/$x509CACNF"
    if [ $? -ne 0 ]; then
        echo "x509CertSign: Certificate Signing Request generation failed" >&2
        return 1
    fi

    declare -a caOptions
    caOptions=("${caOptions[@]}" "-preserveDN")
    if [[ $certV == "3" ]]; then
        caOptions=("${caOptions[@]}" "-extensions" "v3_ext")
    fi
    if [[ ! -z $sigPad ]]; then
        caOptions=("${caOptions[@]}" "-sigopt" "rsa_padding_mode:$sigPad")
    fi
    if [[ ! -z $pssSaltLen ]]; then
        caOptions=("${caOptions[@]}" "-sigopt" "rsa_pss_saltlen:$pssSaltLen")
    fi
    if [[ ! -z $pssMgf1Md ]]; then
        caOptions=("${caOptions[@]}" "-sigopt" "rsa_mgf1_md:$pssMgf1Md")
    fi

    ${x509OPENSSL} ca -config "$caAlias/$x509CACNF" -batch \
        -keyfile "$caAlias/$x509PKEY" \
        -cert "$caAlias/$x509CERT" \
        -in "$kAlias/$x509CSR" \
        -out "$kAlias/$x509CERT" \
        "${caOptions[@]}"
    if [ $? -ne 0 ]; then
        echo "x509CertSign: Signing of the certificate failed" >&2
        return 1
    fi
}

true <<'=cut'
=pod

=head2 x509Key()

Return the key associated with given alias.

=over 4

B<x509Key>
I<alias>
[B<--der>]
[B<--pkcs12>]
[B<--with-cert>]
[B<--pkcs8>]

=back

The function returns on standard output the relative path of the file
that contains the PEM formatted (SSLeay or PKCS#8), unencrypted
private key file.

To be used for simple variable substitution on command line, e.g.:

    openssl rsa -in $(x509Key ca) -noout -text

Note that the function doesn't check if the private file was actually
generated or that conversion to DER format was successful.

=over

=item I<alias>

Name of the key to return key file for

=item B<--der>

Convert a copy of the private key to DER format and output the location of the
DER encoded file (binary, not base64).

=item B<--pkcs12>

Convert a copy of the private key to PKCS#12 format and output the location
of PKCS#12 encoded file. The key will be encrypted with null password and
PKCS#5 v2 PBE/PBKDF and DES-EDE3-CBC cipher (strongest supported by NSS).
Its friendly name will be set to alias.

Note that the export does cache the last exported file, so if you exported the
key or certificate to PKCS#12 format before, you will have to `rm` the previous
file first.

=item B<--with-cert>
When exporting to the PKCS#12 format, include the certificate too.

=item B<--password> I<password>
When exporting to the PKCS#12 format, use the I<password> as the password
of the file. Uses empty string by default

=item B<--pkcs8>

Convert a copy of the private key to PKCS#8 format and output the location
of PKCS#8 encoded file. Can be combined with B<--der>.

Note that the export does cache the last exported file, so if you exported the
key or certificate to PKCS#8 format before, you will have to `rm` the previous
file first.

=back

=cut

x509Key() {

    # generate DER file?
    local der="false"
    # generate PKCS#12 file?
    local pkcs12="false"
    # generate PKCS#8 file?
    local pkcs8="false"
    # include certificate in PKCS#12 file?
    local withCert="false"
    # name of the key to return
    local kAlias
    # password to use for PKCS#12 export
    local password=''

    local TEMP=$(getopt -o h -l der -l pkcs12 -l with-cert -l pkcs8,password:\
        -n x509Key -- "$@")
    if [ $? -ne 0 ]; then
        echo "x509Key: can't parse options" >&2
        return 1
    fi

    eval set -- "$TEMP"

    while true ; do
        case "$1" in
            --der) der="true"; shift 1
                ;;
            --pkcs12) pkcs12="true"; shift 1
                ;;
            --with-cert) withCert="true"; shift 1
                ;;
            --pkcs8) pkcs8="true"; shift 1
                ;;
            --password) password="$2"; shift 2
                ;;
            --) shift 1
                break
                ;;
        esac
    done

    kAlias="$1"

    if [[ $der == "true" ]] && [[ $pkcs12 == "true" ]]; then
        echo "Can't export PKCS#12 and DER together" >&2
        return 1
    fi

    if [[ $pkcs12 == "true" ]] && [[ $pkcs8 == "true" ]]; then
        echo "Can't export PKCS#12 and PKCS#8 together" >&2
        return 1
    fi

    if [[ $der == "true" ]]; then
        if [[ $pkcs8 == "true" ]]; then
            if [[ ! -e $kAlias/$x509PKCS8DERKEY ]]; then
                ${x509OPENSSL} pkcs8 -topk8 -in "$kAlias/$x509PKEY" -nocrypt \
                    -outform DER -out "$kAlias/$x509PKCS8DERKEY"
            fi
            echo "$kAlias/$x509PKCS8DERKEY"
        else
            if [[ ! -e $kAlias/$x509DERKEY ]]; then
                # openssl 0.9.8 doesn't have pkey subcommand, simulate it with
                # rsa and dsa subcommands, ec subcommand is not supported there
                if ${x509OPENSSL} version | grep -q '0[.]9[.].'; then
                    if [[ -e "$kAlias/dsa_params.pem" ]]; then
                        ${x509OPENSSL} dsa -in "$kAlias/$x509PKEY" \
                            -outform DER -out "$kAlias/$x509DERKEY"
                    elif grep -q 'BEGIN RSA PRIVATE KEY' "$kAlias/$x509PKEY" \
                        || grep -q 'BEGIN PRIVATE KEY' "$kAlias/$x509PKEY"; then
                        ${x509OPENSSL} rsa -in "$kAlias/$x509PKEY" \
                            -outform DER -out "$kAlias/$x509DERKEY"
                    else
                        echo "Private key in unknown format" >&2
                        return 1
                    fi

                else
                    ${x509OPENSSL} pkey -in "$kAlias/$x509PKEY" -outform DER \
                        -out "$kAlias/$x509DERKEY"
                fi
            fi
            echo "$kAlias/$x509DERKEY"
        fi
    elif [[ $pkcs12 == "true" ]]; then
        if [[ ! -e $kAlias/$x509PKCS12 ]]; then
            local -a options
            options=(-export -out "$kAlias/$x509PKCS12"
                     -passout "pass:$password"
                     -inkey "$kAlias/$x509PKEY" -name "$kAlias")
            # NSS doesn't support MACs other than MD5 and SHA1, or encryption
            # stronger than 3DES, see RHBZ#1220573
            # old OpenSSL doesn't support setting MAC at all
            if ${x509OPENSSL} version | grep -q '0[.]9[.].'; then
                options=(${options[@]} -keypbe PBE-SHA1-3DES)
            else
                options=(${options[@]} -keypbe DES-EDE3-CBC -macalg SHA1)
            fi

            if [[ $withCert == "true" ]]; then
                options=("${options[@]}" -in "$kAlias/$x509CERT"
                         -caname "$kAlias")

                # old OpenSSL versions don't support no encryption on certs
                # use the weakest suppported by current (2015) FIPS
                if ${x509OPENSSL} version | grep -q '0[.]9[.]7'; then
                    options=(${options[@]} -certpbe PBE-SHA1-3DES)
                else
                    options=(${options[@]} -certpbe NONE)
                fi
            else
                if ${x509OPENSSL} version | grep -q '0[.]9[.]7'; then
                    echo "Export without certificate unsupported with this version of OpenSSL, try --with-cert" >&2
                    return 1
                fi
                options=("${options[@]}" -nocerts)
            fi
            ${x509OPENSSL} pkcs12 ${options[@]}
            if [[ $? -ne 0 ]]; then
                echo "Key export failed" >&2
                return 1
            fi
        fi
        echo "$kAlias/$x509PKCS12"
    elif [[ $pkcs8 == "true" ]]; then
        if [[ ! -e $kAlias/$x509PKCS8KEY ]]; then
            ${x509OPENSSL} pkcs8 -topk8 -in "$kAlias/$x509PKEY" -nocrypt \
                -out "$kAlias/$x509PKCS8KEY"
        fi
        echo "$kAlias/$x509PKCS8KEY"
    else
        echo "$kAlias/$x509PKEY"
    fi
}

true <<'=cut'
=pod

=head2 x509Cert()

Return the certificate associated with given alias.

=over 4

B<x509Cert>
I<alias>
[B<--der>]
[B<--pkcs12>]

=back

The function returns on standard output the relative path of the file
that contains the PEM formatted X.509 certificate associated with provided
alias.

To be used for simple variable substitution on command line, e.g.:

    openssl x509 -in $(x509Cert ca) -noout -text

Note that the function doesn't check if the certificate was actually signed
before.

Note that the DER format and PKCS#12 format files are cached, as such, if you
regenerated certificate you will have to remove them to get the new cert in
those formats.

=over

=item I<alias>

Name of the certificate-key pair to return the certificate for.

=item B<--der>

Convert a copy of the certificate to the DER format and print on standard
output the file name of the copy.

=item B<--pkcs12>

Convert a copy of the certificate to the PKCS#12 format and print on standard
output the file name of the copy. Friendly name of the certificate in PKCS#12
file is set to the alias.

=item B<--password> I<password>
When exporting to the PKCS#12 format, use the I<password> as the password
of the file. Uses empty string by default

=back

=cut

x509Cert() {

    # generate DER file?
    local der="false"
    # generate PKCS12 file?
    local pkcs12="false"
    # password to use (empty by default)
    local password=""
    # name of the key to return
    local kAlias

    local TEMP=$(getopt -o h -l der -l pkcs12 -l password:\
        -n x509Cert -- "$@")
    if [ $? -ne 0 ]; then
        echo "x509Cert: can't parse options" >&2
        return 1
    fi

    eval set -- "$TEMP"

    while true ; do
        case "$1" in
            --der) der="true"; shift 1
                ;;
            --pkcs12) pkcs12="true"; shift 1
                ;;
            --password) password="$2"; shift 2
                ;;
            --) shift 1
                break
                ;;
        esac
    done

    if [ $der == "true" ] && [ $pkcs12 == "true" ]; then
        echo "Can't export DER and PKCS12 files at the same time!" >&2
        return 1
    fi

    kAlias="$1"

    if [[ $der == "true" ]]; then
        if [[ ! -e $kAlias/$x509DERCERT ]]; then
            ${x509OPENSSL} x509 -in "$kAlias/$x509CERT" -outform DER \
                -out "$kAlias/$x509DERCERT"
            if [ $? -ne 0 ]; then
                echo "File conversion failed" >&2
                return 1
            fi
        fi
        echo "$kAlias/$x509DERCERT"
    elif [[ $pkcs12 == "true" ]]; then
        if [[ ! -e $kAlias/$x509PKCS12 ]]; then
            local -a options
            options=(-export -out "$kAlias/$x509PKCS12"
                     -in "$kAlias/$x509CERT" -caname "$kAlias"
                     -nokeys -passout "pass:$password")

            # Old OpenSSL versions don't support lack of encryption on
            # certificate, use the weakest supported by current (2015) FIPS
            if ${x509OPENSSL} version | grep -q '0[.]9[.]7'; then
                options=(${options[@]} -certpbe PBE-SHA1-3DES)
            else
                options=(${options[@]} -certpbe NONE)
            fi

            # note that NSS doesn't support MACs other that MD5 and SHA1
            # see RHBZ#1220573
            # older version of openssl don't support setting MAC at all
            if ${x509OPENSSL} version | grep -q '0[.]9[.].'; then
                :
            else
                options=(${options[@]} -macalg SHA1)
            fi

            local ret
            ${x509OPENSSL} pkcs12 "${options[@]}"
            ret=$?

            # old openssl has broken return codes...
            if ! ${x509OPENSSL} version | grep -q '0[.]9[.]7'; then
                if [ $ret -ne 0 ]; then
                    echo "File conversion failed" >&2
                    return 1
                fi
            fi
        fi
        echo "$kAlias/$x509PKCS12"
    else
        echo "$kAlias/$x509CERT"
    fi
}

true <<'=cut'
=pod

=head2 x509DumpCert()

Output text version of certificate to standard output

=over 4

B<x509DumpCert>
I<alias>

=back

Used as a shorthand for C<openssl x509>:

    openssl x509 -in $(x509Cert alias) -noout -text

=over

=item I<alias>

Specify the name of the certificate to dump

=back

=cut

x509DumpCert(){

    ${x509OPENSSL} x509 -in $(x509Cert "$1") -noout -text
}

true <<'=cut'
=pod

=head2 x509RmAlias()

Remove private key, certificate and settings related to given alias.

=over 4

B<x509RmAlias>
I<alias>

=back

=over

=item I<alias>

Name of the private key to remove

=back

=cut

x509RmAlias() {

    if [[ -e $1/$x509PKEY ]]; then
        rm -rf "$1"
        return $?
    else
        echo "Alias does not refer to certgen library directory" >&2
        return 1
    fi
}

true <<'=cut'
=pod

=head2 x509Revoke()

Revoke a certificate.

=over 4

B<x509Revoke>
B<--CA> I<CAAlias>
[B<--crlReason> I<REASON>]
[B<--crlCompromiseTime> I<REASON>]
[B<--crlCACompromiseTime> I<REASON>]
I<alias>

=back

=over

=item B<--CA> I<CAAlias>

The CA alias which issued the certificate to be revoked.

The specified CA must have issued the certificate to be revoked.

=back

=item B<--crlReason> I<REASON>

The reason for the certificate to be revoked.

Acceptable values are B<unspecified>, B<keyCompromise>, B<CACompromise>,
B<affiliationChanged>, B<superseded>, B<cessationOfOperation>,
B<certificateHold>, and <removeFromCRL>. The matching of reason is case
insensitive. Setting any revocation reason will make the CRL v2.

In practice removeFromCRL is not particularly useful because it is only used in
delta CRLs which are not currently implemented.

=back

=item B<--crlCompromiseTime> I<TIME>

This sets the revocation reason to B<keyCompromise> and the compromise time to
I<TIME>.

I<TIME> should be in GeneralizedTime format that is YYYYMMDDHHMMSSZ

=back

=item B<--crlCACompromiseTime> I<TIME>

Same as B<--crlCompromiseTime> except the revocation reason is set to
B<CACompromise>.

=back

=item I<alias>

The alias for the certificate to be revoked.

=back

=cut

x509Revoke() {
    # alias of the certificate to be revoked
    local kAlias
    # alias of the certificate issuer CA key and cert to be used
    local caAlias
    # reason for certificate revocation
    local crlReason
    # set the compromise time and the reason for revocation
    local crlCompromiseTime
    # set the CA compromise time and the reason for revocation
    local crlCACompromiseTime

    local TEMP=$(getopt -o v:t: -l CA: \
        -l crlReason: \
        -l crlCompromiseTime: \
        -l crlCACompromiseTime: \
        -n x509Revoke -- "$@")

    if [ $? -ne 0 ]; then
        echo "x509Revoke: can't parse options" >&2
        return 1
    fi

    eval set -- "$TEMP"

    while true ; do
        case "$1" in
            --CA) caAlias="$2"; shift 2
                ;;
            --crlReason) crlReason="$2"; shift 2
                ;;
            --crlCompromiseTime) crlCompromiseTime="$2"; shift 2
                ;;
            --crlCACompromiseTime) crlCACompromiseTime="$2"; shift 2
                ;;
            --) shift 1
                break
                ;;
            *) echo "x509Revoke: Unknown option: $1" >&2
                return 1
        esac
    done

    kAlias="$1"

    #
    # sanity check options
    #

    if [ ! -e "$caAlias/$x509PKEY" ]; then
        echo "x509Revoke: CA private key does not exist" >&2
        return 1
    fi

    if [ ! -e "$caAlias/$x509CERT" ]; then
        echo "x509Revoke: CA certificate does not exist" >&2
        return 1
    fi

    if [ ! -e "$caAlias/$x509CACNF" ]; then
        echo "x509Revoke: CA configuration does not exist" >&2
        return 1
    fi

    #
    # set parameters
    #

    local isReasonSet=""
    declare -a parameters

    if [[ ! -z $crlReason ]]; then
        parameters=("${parameters[@]}" "-crl_reason" "$crlReason")
        isReasonSet="True"
    fi

    if [[ ! -z $crlCompromiseTime ]]; then
        if [[ ! -z $isReasonSet ]]; then
            echo "X509Revoke: crlReason, crlCompromiseTime, and "\
                "crlCACompromiseTime are mutually exclusive; choose one" >&2
            return 1
        fi

        parameters=("${parameters[@]}" "-crl_compromise" "$crlCompromiseTime")
        isReasonSet="True"
    fi

    if [[ ! -z $crlCACompromiseTime ]]; then
        if [[ ! -z $isReasonSet ]]; then
            echo "X509Revoke: crlReason, crlCompromiseTime, and "\
                "crlCACompromiseTime are mutually exclusive; choose one" >&2
            return 1
        fi
        parameters=("${parameters[@]}" "-crl_CA_compromise" "$crlCACompromiseTime")
        isReasonSet="True"
    fi

    ${x509OPENSSL} ca -config "$caAlias/$x509CACNF" -batch \
        -keyfile "$caAlias/$x509PKEY" \
        -cert "$caAlias/$x509CERT" \
        -revoke "$kAlias/$x509CERT" \
        "${parameters[@]}"
    if [ $? -ne 0 ]; then
        echo "x509Revoke: Failed to revoke certificate" >&2
        return 1
    fi
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Execution
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 EXECUTION

This library works correctly only when sourced. I.e.:

    . ./lib.sh

=over

=back

=cut

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Verification
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   This is a verification callback which will be called by
#   rlImport after sourcing the library to make sure everything is
#   all right. The function should return 0 only when the library
#   is ready to serve.

x509LibraryLoaded() {
    local ret
    getopt -T
    ret=$?
    if [ ${ret} -ne 4 ]; then
        echo "certgen: error: "\
            "Non GNU enhanced version of getopt" 1>&2
        return 1
    fi

    return 0
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Authors
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 X.509 EXTENSIONS

Version 3 certificates differ from version 1 certificates in that they can
be extended with arbitrary data.
Some of those exensions were standardised and can be used freely.

Note that extension marked as critical will cause certificate validation
failure if the validator does not know or understand the extension.
For common extensions like Basic Constraints or Key Usage it is highly
recommended to leave them critical, on the other hand, other types
of extensions should I<not> be marked as such.

Most important ones are:

=over

=item B<Basic Constraints>

Notifies certificate validator if the certificate is used by a Certification
Authority and how long can be the chain of intermediate certificates.

This extension should be marked as critical.

=item B<Basic Key Usage>

Sets how the certificate can be used with regards to low level cryptography
operations and basic PKI operations.

Full list includes:

=over

=item I<digitalSignature>

Signing hashed data. For example used for DHE and ECDHE suites.
I<Not> used for certificate or CRL signing.

=item I<nonRepudiation>

Proof of orgin and integrity of data, not used in TLS context.
I<Not> used for certificate or CRL signing.

=item I<keyEncipherment>

Encrypting keying material, used with TLS cipher suites that use RSA key
exchange.

=item I<dataEncipherment>

Encrypting data directly other than cryptographic keys.

=item I<keyAgreement>

Used when key is used for encryption key agreement. Used for DHE and ECDHE
cipher sutes.

=item I<keyCertSign>

Used for signing certificates. Note that the I<CA> bit in B<Basic Key Usage>
must also be set for this value to be effective.

=item I<cRLSign>

Used when signing CRL files. Not that the I<CA> bit in B<Basic Key Usage>
must also be set for this value to be effective.

=item I<encipherOnly>

Used together with I<keyAgreement> bit, marks the public key as usable only
for enciphering data when performing key agreement.

=item I<decipherOnly>

Used together with I<keyAgreement> bit, marks the public key as usable only
for deciphering data when performing key agreement.

=back

=back

=head1 AUTHORS

=over

=item *

Hubert Kario <hkario@redhat.com>

=back

=cut
