#!/bin/bash

# This script automatically generates and signs OpenVPN client certificates and profiles by using a remote CA server through SSH
# On the OpenVPN server, the PKI must be located at ~/easy-rsa/
#     (https://www.digitalocean.com/community/tutorials/how-to-set-up-and-configure-an-openvpn-server-on-ubuntu-20-04)
#
# On the Certificate Authority server, the PKI must be located at ~/easy-rsa/
#     (https://www.digitalocean.com/community/tutorials/how-to-set-up-and-configure-a-certificate-authority-ca-on-ubuntu-20-04)
#
# Under the Script Config section you can configure the SSH parameters of the CA server. This script only supports key-based authentication.
#
# /etc/openvpn/ccd

###################
#  Script Config  #
###################
CONF_CA_SERVER_HOST="firestormsw.com"
CONF_CA_SERVER_USER="ca"
CONF_CA_IDENTITY="~/.ssh/id_firestorm_ca"


###################
#  Sanity Checks  #
###################
cd ~/easy-rsa
client_name=$1
client_ip=$2

if [ $# -eq 0 ]; then
	echo "Please provide a client name."
	echo "Correct usasge: ./`basename $0` client_name [fixed_ip]"
	echo "    client_name - The CN of the client certificate, and the name of the VPN client"
	echo "    fixed_ip    - A static IP address to be assigned to this client (optional)"
	echo "Example usage: ./`basename $0` client1 10.8.0.12"
	exit 1
fi

if [ $# -eq 2 ]; then

	# Check if CCD path is configured in server.conf
	ccd_path=`cat /etc/openvpn/server/server.conf | grep "^client-config-dir" | cut -d ';' -f 1 | cut -d ' ' -f 2`
	if [ ! -d "$ccd_path" ]; then
		echo "A fixed IP address was specified, but the CCD path doesn't seem to exist."
		echo "Make sure to configure a CCD path in /etc/openvpn/server/server.conf by adding the directive 'client-config-dir' and setting it to a valid path."
		echo "Example:"
		echo "  client-config-dir=/etc/openvpn/ccd"
		exit 1
	fi

	# Check the topology type
	topology=`cat /etc/openvpn/server/server.conf | grep "^topology" | cut -d ';' -f 1 | cut -d ' ' -f 2`
	if [ $topology != "subnet" ]; then
		echo "The current network topology should be configured as 'subnet', but instead it seems to be '$topology'."
		echo "This might restrict the number of IP addresses that can be configured as static, and this script won't perform any checks to validate the provided address."
		echo "Are you sure you want to continue? (type yes to confirm, anything else to abort)"
		read top_confirm
		if [ $top_confirm != "yes" ]; then
			exit 0
		fi
	fi

	# Check if the directory is writeable
	if [ ! -w "$ccd_path" ]; then
		echo "The configured CCD directory is not writeable. Either run this script as a root user, or make the folder accessible to the current user."
		echo "CCD Path: $ccd_path"
		exit 1
	fi

	echo "ifconfig-push $client_ip 255.255.255.0" > "$ccd_path/$client_name"
fi


#################
#  Script Code  #
#################
echo "###### GENERATING CERT. SIGNING REQUEST ######"
rm -f /home/bitnami/easy-rsa/pki/private/$client_name.key
echo -ne '\n' | ./easyrsa gen-req $client_name nopass

echo "###### UPLOADING CERT. SIGNING REQUEST TO CA SERVER ######"
mkdir ~/client-configs/keys/
cp ./pki/private/$client_name.key ~/client-configs/keys/
scp -i "$CONF_CA_IDENTITY" ./pki/reqs/$client_name.req $CONF_CA_SERVER_USER@$CONF_CA_SERVER_HOST:/tmp

echo "###### (REM.) IMPORTING SIGNING REQUEST ######"
ssh -i "$CONF_CA_IDENTITY" $CONF_CA_SERVER_USER@$CONF_CA_SERVER_HOST \
	"cd /home/$CONF_CA_SERVER_USER/easy-rsa && rm -f ./pki/reqs/$client_name.req  && ./easyrsa import-req /tmp/$client_name.req $client_name"

echo "###### (REM.) SIGNING THE CERTIFICATE ######"
ssh -i "$CONF_CA_IDENTITY" $CONF_CA_SERVER_USER@$CONF_CA_SERVER_HOST \
	"cd /home/$CONF_CA_SERVER_USER/easy-rsa && echo yes | ./easyrsa sign-req client $client_name"

echo "###### DOWNLOADING SIGNED SERTIFICATE ######"
scp -i "$CONF_CA_IDENTITY" $CONF_CA_SERVER_USER@$CONF_CA_SERVER_HOST:/home/$CONF_CA_SERVER_USER/easy-rsa/pki/issued/$client_name.crt ~/client-configs/keys/

cd ~/easy-rsa

echo "###### GENERATING OPENVPN PROFILE ######"
KEY_DIR=~/client-configs/keys
OUTPUT_DIR=~/client-configs/files
BASE_CONFIG=~/client-configs/base.conf

cat ${BASE_CONFIG} \
    <(echo -e '<ca>') \
    ${KEY_DIR}/ca.crt \
    <(echo -e '</ca>\n<cert>') \
    ${KEY_DIR}/$client_name.crt \
    <(echo -e '</cert>\n<key>') \
    ${KEY_DIR}/$client_name.key \
    <(echo -e '</key>\n<tls-crypt>') \
    ${KEY_DIR}/ta.key \
    <(echo -e '</tls-crypt>') \
    > ${OUTPUT_DIR}/$client_name.ovpn

echo "Output configuration file for client '$client_name' was written to: ${OUTPUT_DIR}/$client_name.ovpn"
