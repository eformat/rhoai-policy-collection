#!/bin/bash

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly NC='\033[0m' # No Color
readonly RUN_DIR=$(pwd)

export NO_ADMINS=${NO_ADMINS:-1}

create_htpasswd() {
    echo "🌴 Running create_htpasswd..."
    for x in $(seq 1 ${NO_ADMINS}); do
        if [ "$x" == 1 ]; then
            htpasswd -bBc /tmp/htpasswd admin ${ADMIN_PASSWORD}
        else
            htpasswd -bB /tmp/htpasswd admin$x ${ADMIN_PASSWORD}
        fi
        if [ "$?" != 0 ]; then
            echo -e "🚨${RED}Failed - to run create_htpasswd ?${NC}"
            exit 1
        fi
    done
    echo "🌴 create_htpasswd ran OK"
}

add_cluster_admins() {
    echo "🌴 Running add_cluster_admins..."
    for x in $(seq 1 ${NO_ADMINS}); do
        if [ "$x" == 1 ]; then
            oc adm policy add-cluster-role-to-user cluster-admin admin
        else
            oc adm policy add-cluster-role-to-user cluster-admin admin$x
        fi
        if [ "$?" != 0 ]; then
            echo -e "🚨${RED}Failed - to run add_cluster_admins ?${NC}"
            exit 1
        fi
    done
    echo "🌴 add_cluster_admins ran OK"
}

configure_oauth() {
    echo "🌴 Running configure_oauth..."
    oc delete secret htpasswdidp-secret -n openshift-config
    oc create secret generic htpasswdidp-secret -n openshift-config --from-file=/tmp/htpasswd

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to create secret, configure_oauth ?${NC}"
      exit 1
    fi

cat << EOF > /tmp/htpasswd.yaml
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: htpasswd_provider
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpasswdidp-secret
EOF

    oc apply -f /tmp/htpasswd.yaml -n openshift-config
    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to create oauth, configure_oauth ?${NC}"
      exit 1
    fi

    oc delete secret kubeadmin -n kube-system 2>&1 | tee /tmp/oc-error-file
    if [ "$?" != 0 ]; then
        if grep -q "not found" /tmp/oc-error-file; then
            echo -e "${GREEN}Ignoring - kubeadmin does not exist${NC}"
        else
            echo -e "🚨${RED}Failed - to delete kubeadmin, configure_oauth ?${NC}"
            exit 1
        fi
    fi
    echo "🌴 configure_oauth ran OK"
}

check_done() {
    echo "🌴 Running check_done..."
    ID=$(oc get oauth.config.openshift.io cluster -o=jsonpath={.spec.identityProviders[].type})
    if [ "$ID" != "HTPasswd" ]; then
      echo -e "💀${ORANGE}Warn - check_done not ready for users, continuing ${NC}"
      return 1
    else
      echo "🌴 check_done ran OK"
    fi
    return 0
}

all() {
    echo "🌴 BASE_DOMAIN set to $BASE_DOMAIN"
    echo "🌴 NO_ADMINS set to $NO_ADMINS"

    if check_done; then return; fi

    create_htpasswd
    add_cluster_admins
    configure_oauth
}

# Check for EnvVars
[ -z "$BASE_DOMAIN" ] && echo "🕱 Error: must supply BASE_DOMAIN in env or cli" && exit 1
[ -z "$ADMIN_PASSWORD" ] && read -s -p "ADMIN_PASSWORD: " ADMIN_PASSWORD

all

echo -e "\n🌻${GREEN}Users configured OK.${NC}🌻\n"
exit 0