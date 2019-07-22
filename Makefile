PROJECT = "MOJA-BOX"
dir = $(shell pwd)
include ./config/.compiled_env
env_dir := $(dir)/config


##
# Env
##

env:
	cat ${env_dir}/mojaloop.public.sh ${env_dir}/mojaloop.private.sh > ${env_dir}/.compiled_env


##
# Deployment
##
deploy-kube:
	@cd ./terraform && terraform apply -target=module.cluster -target=module.network


destroy-kube:
	@cd ./terraform && terraform destroy -target=module.cluster -target=module.network

deploy-dns:
	@cd ./terraform && terraform apply -target=module.dns

destroy-dns:
	@cd ./terraform && terraform destroy -target=module.dns

deploy-infra-destroy:
	@cd ./terraform && terraform destroy

deploy-helm:	
	#get the currently running clusters
	gcloud container clusters list
	gcloud container clusters get-credentials moja-box-cluster

	#init helm
	helm init

	#Fix up permissions for helm to work
	make helm-fix-permissions
	kubectl -n kube-system get pod | grep tiller

	@echo 'Not deploying-moja - make sure to set up CLUSTER_IP manually'

deploy-moja:
	@echo 'Installing Mojaloop'
	helm repo add mojaloop http://mojaloop.io/helm/repo/
	helm install --debug --namespace=mojaloop --name=dev --repo=http://mojaloop.io/helm/repo mojaloop
	helm repo update

	@echo installing Nginx
	helm --namespace=mojaloop install stable/nginx-ingress --name=nginx

	@make print-hosts-settings

	@echo installing Kubernetes dasboard
	helm install stable/kubernetes-dashboard \
		--namespace kube-dash \
		--name kube-dash \
  	--set rbac.clusterAdminRole=true,enableSkipLogin=true,enableInsecureLogin=true

deploy-vt-ingress:
	#TODO: integrate this into the original thingo
	helm upgrade  -f ./ingress.values.yml --repo http://mojaloop.io/helm/repo dev mojaloop

deploy:
	make deploy-kube
	make deploy-helm
	make deploy-moja
	#Load balancer will be live now, we can set up the lb env var
	@make config-set-lb-ip
	make deploy-dns

##
# Configuration
##
config-all:
	@make config-set-up config-create-dfsps

config-set-up:
	@make env
	@./mojaloop_config/00_set_up_env.sh
	@echo 'Done!'

config-create-dfsps:
	@make env
	@./mojaloop_config/01_create_dfsps.sh
	@echo 'Done!'

# set the correct load balancer ip
# we rely on a separate script as variable subs
# in make are hard
config-set-lb-ip:
	@./config/_set_up_lb_ip.sh
	@make env



##
# Apply values for helm that changes the LOG_LEVEL to debug
##
config-enable-debug:
	helm upgrade -f ./debug.values.yml --repo http://mojaloop.io/helm/repo dev mojaloop


##
# Examples
##
example-create-transfer:
	@./mojaloop_config/02_create_transfer.sh


##
# Misc
## 
helm-fix-permissions:
	@helm list || echo 'command failed'

	#Give helm the necessary permissions to install stuff on the cluster
	kubectl -n kube-system delete serviceAccounts tiller || echo 'nothing to delete'
	kubectl -n kube-system delete clusterrolebindings tiller-cluster-rule || echo 'nothing to delete'
	kubectl create serviceaccount --namespace kube-system tiller
	kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller

	#patch the permissions
	kubectl patch deploy --namespace kube-system tiller-deploy -p '{"spec":{"template":{"spec":{"serviceAccount":"tiller"}}}}'
	helm init --service-account tiller --upgrade
	sleep 10

	helm list || echo 'helm list failed. May not be fatal'


print-hosts-settings:
	@echo "Make sure your /etc/hosts contains the following:\n"
	@echo '  ${CLUSTER_IP}	interop-switch.local central-kms.local forensic-logging-sidecar.local central-ledger.local central-end-user-registry.local central-directory.local central-hub.local central-settlement.local ml-api-adapter.local'

proxy-kube-dash:
	@echo "Go to: http://localhost:8002/api/v1/namespaces/kube-dash/services/kube-dash-kubernetes-dashboard:http/proxy/"
	@kubectl proxy --port 8002

health-check:
	@make env
	curl -H Host:'central-ledger.local' http://${CLUSTER_IP}/health

print-ip:
	echo 'Warning! This is the cluster endpoint, and not the loadbalancer endpoint!'
	@cd ./terraform && terraform output |  grep loadbalancer | awk 'BEGIN { FS = " = " }; { print $$2 }'

print-endpoints:
	@kubectl get ep -n mojaloop

print-lb-ip:
	@gcloud compute forwarding-rules list | tail -1 | cut -f5 -d " "


remove-helm:
	helm reset --force


.PHONY: switch switch-dev swich-prod env