# Copyright 2022 The k8gb Contributors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Generated by GoLic, for more details see: https://github.com/AbsaOSS/golic
###############################
#       DOTENV
###############################
ifneq ($(wildcard ./.env),)
	include .env
	export
endif

###############################
#		CONSTANTS
###############################
CLUSTERS_NUMBER ?= 2
CLUSTER_IDS = $(shell seq $(CLUSTERS_NUMBER))
CLUSTER_NAME ?= test-gslb
CLUSTER_GEO_TAGS ?= eu us cz af ru ap uk ca
CHART ?= k8gb/k8gb
CLUSTER_GSLB_NETWORK = k3d-action-bridge-network
CLUSTER_GSLB_GATEWAY = docker network inspect ${CLUSTER_GSLB_NETWORK} -f '{{ (index .IPAM.Config 0).Gateway }}'
GSLB_DOMAIN ?= cloud.example.com
REPO := absaoss/k8gb
SHELL := bash
VALUES_YAML ?= ""
PODINFO_IMAGE_REPO ?= ghcr.io/stefanprodan/podinfo
HELM_ARGS ?=
K8GB_COREDNS_IP ?= kubectl get svc k8gb-coredns -n k8gb -o custom-columns='IP:spec.clusterIP' --no-headers
LOG_FORMAT ?= simple
LOG_LEVEL ?= debug
CONTROLLER_GEN_VERSION  ?= v0.8.0
GOLIC_VERSION  ?= v0.7.2
GOKART_VERSION ?= v0.2.0
POD_NAMESPACE ?= k8gb
CLUSTER_GEO_TAG ?= eu
EXT_GSLB_CLUSTERS_GEO_TAGS ?= us
EDGE_DNS_SERVER ?= 1.1.1.1
EDGE_DNS_ZONE ?= example.com
DNS_ZONE ?= cloud.example.com
DEMO_URL ?= http://failover.cloud.example.com
DEMO_DEBUG ?=0
DEMO_DELAY ?=5
GSLB_CRD_YAML ?= chart/k8gb/templates/crds/k8gb.absa.oss_gslbs.yaml

ifndef NO_COLOR
YELLOW=\033[0;33m
CYAN=\033[1;36m
RED=\033[31m
# no color
NC=\033[0m
endif

NO_VALUE ?= no_value

###############################
#		VARIABLES
###############################
PWD ?=  $(shell pwd)
VERSION ?= $(shell git describe --tags --abbrev=0)
COMMIT_HASH ?= $(shell git rev-parse --short HEAD)
SEMVER ?= $(VERSION)-$(COMMIT_HASH)
# image URL to use all building/pushing image targets
IMG ?= $(REPO):$(VERSION)
STABLE_VERSION := "stable"
# default bundle image tag
BUNDLE_IMG ?= controller-bundle:$(VERSION)

# options for 'bundle-build'
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# create GOBIN if not specified
ifndef GOBIN
GOBIN=$(shell go env GOPATH)/bin
endif

###############################
#		TARGETS
###############################

all: help

# check integrity
.PHONY: check
check: license lint gokart test ## Check project integrity

.PHONY: clean-test-apps
clean-test-apps:
	kubectl delete -f deploy/test-apps
	helm -n test-gslb uninstall frontend

# see: https://dev4devs.com/2019/05/04/operator-framework-how-to-debug-golang-operator-projects/
.PHONY: debug-idea
debug-idea: export WATCH_NAMESPACE=test-gslb
debug-idea:
	$(call debug,debug --headless --listen=:2345 --api-version=2)

.PHONY: demo
demo: ## Execute end-to-end demo
	@$(call demo-host, $(DEMO_URL))

# spin-up local environment
.PHONY: deploy-full-local-setup
deploy-full-local-setup: ensure-cluster-size ## Deploy full local multicluster setup (k3d >= 5.1.0)
	@echo -e "\n$(YELLOW)Creating $(CLUSTERS_NUMBER) k8s clusters$(NC)"
	$(MAKE) create-local-cluster CLUSTER_NAME=edge-dns
	@for c in $(CLUSTER_IDS); do \
		$(MAKE) create-local-cluster CLUSTER_NAME=$(CLUSTER_NAME)$$c ;\
	done

	$(MAKE) deploy-stable-version DEPLOY_APPS=true

.PHONY: deploy-stable-version
deploy-stable-version:
	$(call deploy-edgedns)
	@for c in $(CLUSTER_IDS); do \
		$(MAKE) deploy-local-cluster CLUSTER_ID=$$c ;\
	done

.PHONY: deploy-test-version
deploy-test-version: ## Upgrade k8gb to the test version on existing clusters
	$(call deploy-edgedns)
	@echo -e "\n$(YELLOW)import k8gb docker image to all $(CLUSTERS_NUMBER) clusters$(NC)"

	@for c in $(CLUSTER_IDS); do \
		echo -e "\n$(CYAN)$(CLUSTER_NAME)$$c:$(NC)" ;\
		k3d image import $(REPO):$(SEMVER)-amd64 --mode=tools-node -c $(CLUSTER_NAME)$$c ;\
	done

	@for c in $(CLUSTER_IDS); do \
		$(MAKE) deploy-local-cluster CLUSTER_ID=$$c VERSION=$(SEMVER)-amd64 CHART='./chart/k8gb' ;\
		kubectl apply -n k8gb -f ./deploy/test/coredns-tcp-svc.yaml ;\
	done

.PHONY: list-running-pods
list-running-pods:
	@for c in $(CLUSTER_IDS); do \
		echo -e "\n$(YELLOW)Local cluster $(CYAN)$(CLUSTER_NAME)$$c $(NC)" ;\
		kubectl get pods -A --context=k3d-$(CLUSTER_NAME)$$c ;\
	done

create-local-cluster:
	@echo -e "\n$(YELLOW)Create local cluster $(CYAN)$(CLUSTER_NAME) $(NC)"
	k3d cluster create -c k3d/$(CLUSTER_NAME).yaml

.PHONY: deploy-local-cluster
deploy-local-cluster:
	@if [ -z "$(CLUSTER_ID)" ]; then echo invalid CLUSTER_ID value && exit 1; fi
	@echo -e "\n$(YELLOW)Deploy local cluster $(CYAN)$(CLUSTER_NAME)$(CLUSTER_ID) $(NC)"
	kubectl config use-context k3d-$(CLUSTER_NAME)$(CLUSTER_ID)

	@echo -e "\n$(YELLOW)Create namespace $(NC)"
	kubectl apply -f deploy/namespace.yaml

	@echo -e "\n$(YELLOW)Deploy GSLB operator from $(VERSION) $(NC)"
	$(MAKE) deploy-k8gb-with-helm

	@echo -e "\n$(YELLOW)Deploy Ingress $(NC)"
	helm repo add --force-update nginx-stable https://kubernetes.github.io/ingress-nginx
	helm repo update
	helm -n k8gb upgrade -i nginx-ingress nginx-stable/ingress-nginx \
		--version 3.24.0 -f deploy/ingress/nginx-ingress-values.yaml

	@if [ "$(DEPLOY_APPS)" = true ]; then $(MAKE) deploy-test-apps ; fi

	@echo -e "\n$(YELLOW)Wait until Ingress controller is ready $(NC)"
	$(call wait-for-ingress)

	@echo -e "\n$(CYAN)$(CLUSTER_NAME)$(CLUSTER_ID) $(YELLOW)deployed! $(NC)"

.PHONY: deploy-test-apps
deploy-test-apps: ## Deploy Podinfo (example app) and Apply Gslb Custom Resources
	@echo -e "\n$(YELLOW)Deploy GSLB cr $(NC)"
	kubectl apply -f deploy/crds/test-namespace.yaml
	$(call apply-cr,deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr.yaml)
	$(call apply-cr,deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr_failover.yaml)

	@echo -e "\n$(YELLOW)Deploy podinfo $(NC)"
	kubectl apply -f deploy/test-apps
	helm repo add podinfo https://stefanprodan.github.io/podinfo
	helm upgrade --install frontend --namespace test-gslb -f deploy/test-apps/podinfo/podinfo-values.yaml \
		--set ui.message="`$(call get-cluster-geo-tag)`" \
		--set image.repository="$(PODINFO_IMAGE_REPO)" \
		podinfo/podinfo \
		--version 5.1.1

.PHONY: upgrade-candidate
upgrade-candidate: release-images deploy-test-version

.PHONY: deploy-k8gb-with-helm
deploy-k8gb-with-helm:
	@if [ -z "$(CLUSTER_ID)" ]; then echo invalid CLUSTER_ID value && exit 1; fi
	# create rfc2136 secret
	kubectl -n k8gb create secret generic rfc2136 --from-literal=secret=96Ah/a2g0/nLeFGK+d/0tzQcccf9hCEIy34PoXX2Qg8= || true
	helm repo add --force-update k8gb https://www.k8gb.io
	cd chart/k8gb && helm dependency update
	helm -n k8gb upgrade -i k8gb $(CHART) -f $(VALUES_YAML) \
		--set $(call get-helm-args,$(CLUSTER_ID)) \
		--set k8gb.reconcileRequeueSeconds=10 \
		--set k8gb.dnsZoneNegTTL=10 \
		--set k8gb.imageTag=${VERSION:"stable"=""} \
		--set k8gb.log.format=$(LOG_FORMAT) \
		--set k8gb.log.level=$(LOG_LEVEL) \
		--set rfc2136.enabled=true \
		--set k8gb.edgeDNSServers[0]=$(shell $(CLUSTER_GSLB_GATEWAY)):1053 \
		--set externaldns.image=absaoss/external-dns:rfc-ns1 \
		--wait --timeout=2m0s

.PHONY: deploy-gslb-operator
deploy-gslb-operator: ## Deploy k8gb operator
	kubectl apply -f deploy/namespace.yaml
	cd chart/k8gb && helm dependency update
	helm -n k8gb upgrade -i k8gb chart/k8gb -f $(VALUES_YAML) $(HELM_ARGS) \
		--set k8gb.log.format=$(LOG_FORMAT)
		--set k8gb.log.level=$(LOG_LEVEL)

# destroy local test environment
.PHONY: destroy-full-local-setup
destroy-full-local-setup: ## Destroy full local multicluster setup
	k3d cluster delete edgedns
	@for c in $(CLUSTER_IDS); do \
		k3d cluster delete $(CLUSTER_NAME)$$c ;\
	done

.PHONY: deploy-prometheus
deploy-prometheus:
	@for c in $(CLUSTER_IDS); do \
		$(call deploy-prometheus,$(CLUSTER_NAME)$$c) ;\
	done

.PHONY: uninstall-prometheus
uninstall-prometheus:
	@for c in $(CLUSTER_IDS); do \
		$(call uninstall-prometheus,$(CLUSTER_NAME)$$c) ;\
	done

.PHONY: deploy-grafana
deploy-grafana:
	@echo -e "\n$(YELLOW)Local cluster $(CYAN)$(CLUSTER_NAME)1$(NC)"
	@echo -e "\n$(YELLOW)install grafana $(NC)"
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo update
	helm -n k8gb upgrade -i grafana grafana/grafana -f deploy/grafana/values.yaml \
		--wait --timeout=2m30s \
		--kube-context=k3d-$(CLUSTER_NAME)1
	kubectl --context k3d-$(CLUSTER_NAME)1 apply -f deploy/grafana/dashboard-cm.yaml -n k8gb
	@echo -e "\nGrafana is listening on http://localhost:3000\n"
	@echo -e "🖖 credentials are admin:admin\n"


.PHONY: uninstall-grafana
uninstall-grafana:
	@echo -e "\n$(YELLOW)Local cluster $(CYAN)$(CLUSTER_GSLB1)$(NC)"
	@echo -e "\n$(YELLOW)uninstall grafana $(NC)"
	kubectl --context k3d-$(CLUSTER_NAME)1 delete -f deploy/grafana/dashboard-cm.yaml -n k8gb
	helm uninstall grafana -n k8gb --kube-context=k3d-$(CLUSTER_NAME)1

.PHONY: dns-tools
dns-tools: ## Run temporary dnstools pod for debugging DNS issues
	@kubectl -n k8gb get svc k8gb-coredns
	@kubectl -n k8gb run -it --rm --restart=Never --image=infoblox/dnstools:latest dnstools

.PHONY: dns-smoke-test
dns-smoke-test:
	kubectl -n k8gb run -it --rm --restart=Never --image=infoblox/dnstools:latest dnstools --command -- /usr/bin/dig @k8gb-coredns roundrobin.cloud.example.com

# create and push docker manifest
.PHONY: docker-manifest
docker-manifest:
	docker manifest create ${IMG} \
		${IMG}-amd64 \
		${IMG}-arm64
	docker manifest annotate ${IMG} ${IMG}-arm64 \
		--os linux --arch arm64
	docker manifest push ${IMG}

.PHONY: ensure-cluster-size
ensure-cluster-size:
	@if [ "$(CLUSTERS_NUMBER)" -gt 8 ] ; then \
		echo -e "$(RED)$(CLUSTERS_NUMBER) clusters is probably way too many$(NC)" ;\
		echo -e "$(RED)you will probably hit resource limits or port collisions, gook luck you are on your own$(NC)" ;\
	fi
	@if [ "$(CLUSTERS_NUMBER)" -gt 3 ] ; then \
		./k3d/generate-yaml.sh $(CLUSTERS_NUMBER) ;\
	fi

.PHONY: goreleaser
goreleaser:
	go install github.com/goreleaser/goreleaser@v1.7.0

.PHONY: release-images
release-images: goreleaser
	goreleaser release --snapshot --skip-validate --skip-publish --rm-dist

# build the docker image
.PHONY: docker-build
docker-build: test release-images

# build and push the docker image exclusively for testing using commit hash
.PHONY: docker-test-build-push
docker-push: test
	docker push ${IMG}-$(COMMIT_HASH)-amd64

.PHONY: init-failover
init-failover:
	$(call init-test-strategy, "deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr_failover.yaml")

.PHONY: init-round-robin
init-round-robin:
	$(call init-test-strategy, "deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr.yaml")

# creates infoblox secret in current cluster
.PHONY: infoblox-secret
infoblox-secret:
	kubectl -n k8gb create secret generic infoblox \
		--from-literal=INFOBLOX_WAPI_USERNAME=$${WAPI_USERNAME} \
		--from-literal=INFOBLOX_WAPI_PASSWORD=$${WAPI_PASSWORD}

# GoKart - Go Security Static Analysis
# see: https://github.com/praetorian-inc/gokart
.PHONY: gokart
gokart:
	$(call gokart,--globalsTainted --verbose)

# updates source code with license headers
.PHONY: license
license:
	@echo -e "\n$(YELLOW)Injecting the license$(NC)"
	$(call golic,-t apache2)

# creates ns1 secret in current cluster
.PHONY: ns1-secret
ns1-secret:
	kubectl -n k8gb create secret generic ns1 \
		--from-literal=apiKey=$${NS1_APIKEY}


# runs golangci-lint aggregated linter; see .golangci.yaml for linter list
.PHONY: lint
lint:
	@echo -e "\n$(YELLOW)Running the linters$(NC)"
	@go install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.43.0
	$(GOBIN)/golangci-lint run

# retrieves all targets
.PHONY: list
list:
	@$(MAKE) -pRrq -f $(lastword $(MAKEFILE_LIST)) : 2>/dev/null | awk -v RS= -F: '/^# File/,/^# Finished Make data base/ {if ($$1 !~ "^[#.]") {print $$1}}' | sort | egrep -v -e '^[^[:alnum:]]' -e '^$@$$'

# build k8gb binary
.PHONY: k8gb
k8gb: lint
	$(call generate)
	go build -o bin/k8gb main.go

.PHONY: mocks
mocks:
	go install github.com/golang/mock/mockgen@v1.5.0
	mockgen -source=controllers/providers/assistant/assistant.go -destination=controllers/providers/assistant/assistant_mock.go -package=assistant
	mockgen -source=controllers/providers/dns/dns.go -destination=controllers/providers/dns/dns_mock.go -package=dns
	mockgen -source=controllers/providers/dns/infoblox-client.go -destination=controllers/providers/dns/infoblox-client_mock.go -package=dns
	mockgen -destination=controllers/providers/dns/infoblox-connection_mock.go -package=dns github.com/infobloxopen/infoblox-go-client IBConnector
	$(call golic)

# remove clusters and redeploy
.PHONY: reset
reset:	destroy-full-local-setup deploy-full-local-setup

# run against the configured Kubernetes cluster in ~/.kube/config
.PHONY: run
run: lint
	$(call generate)
	$(call crd-manifest)
	@echo -e "\n$(YELLOW)Running k8gb locally against the current k8s cluster$(NC)"
	LOG_FORMAT=$(LOG_FORMAT) \
	LOG_LEVEL=$(LOG_LEVEL) \
	POD_NAMESPACE=$(POD_NAMESPACE) \
	CLUSTER_GEO_TAG=$(CLUSTER_GEO_TAG) \
	EXT_GSLB_CLUSTERS_GEO_TAGS=$(EXT_GSLB_CLUSTERS_GEO_TAGS) \
	EDGE_DNS_SERVERS=$(EDGE_DNS_SERVER) \
	EDGE_DNS_ZONE=$(EDGE_DNS_ZONE) \
	DNS_ZONE=$(DNS_ZONE) \
	go run ./main.go

.PHONY: stop-test-app
stop-test-app:
	$(call testapp-set-replicas,0)

.PHONY: start-test-app
start-test-app:
	$(call testapp-set-replicas,2)

# run tests
.PHONY: test
test:
	$(call generate)
	$(call crd-manifest)
	@echo -e "\n$(YELLOW)Running the unit tests$(NC)"
	go test ./... -coverprofile cover.out

.PHONY: test-round-robin
test-round-robin:
	@$(call hit-testapp-host, "roundrobin.cloud.example.com")

.PHONY: test-failover
test-failover:
	@$(call hit-testapp-host, "failover.cloud.example.com")

# executes terratests
.PHONY: terratest
terratest: # Run terratest suite
	@$(eval RUNNING_CLUSTERS := $(shell k3d cluster list --no-headers | grep $(CLUSTER_NAME) -c))
	@$(eval TEST_TAGS := $(shell [ $(RUNNING_CLUSTERS) == 2 ] && echo all || echo rr_multicluster))
	@if [ "$(RUNNING_CLUSTERS)" -lt 2 ] ; then \
		echo -e "$(RED)Make sure you run the tests against at least two running clusters$(NC)" ;\
		exit 1;\
	fi
	cd terratest/test/ && go mod download && CLUSTERS_NUMBER=$(RUNNING_CLUSTERS) go test -v -timeout 15m -parallel=12 --tags=$(TEST_TAGS)

.PHONY: website
website:
	@if [ "$(CI)" = "true" ]; then\
		git config remote.origin.url || git remote add -f -t gh-pages origin https://github.com/k8gb-io/k8gb ;\
		git fetch origin gh-pages:gh-pages ;\
		git checkout gh-pages ;\
		git checkout - README.md CONTRIBUTING.md CHANGELOG.md docs/ ;\
		$(MAKE) website ;\
	fi

.PHONY: version
version:
	@echo $(VERSION)

.PHONY: help
help: ## Show this help
	@egrep -h '\s##\s' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

###############################
#		FUNCTIONS
###############################

define deploy-edgedns
	@echo -e "\n$(YELLOW)Deploying EdgeDNS $(NC)"
	kubectl --context k3d-edgedns apply -f deploy/edge/
endef

define apply-cr
	sed -i 's/cloud\.example\.com/$(GSLB_DOMAIN)/g' "$1"
	kubectl apply -f "$1"
	git checkout -- "$1"
endef

define get-cluster-geo-tag
	kubectl -n k8gb describe deploy k8gb |  awk '/CLUSTER_GEO_TAG/ { printf $$2 }'
endef

nth-geo-tag = $(subst $1_,,$(filter $1_%, $(join $(addsuffix _,$(CLUSTER_IDS)),$(CLUSTER_GEO_TAGS))))

define get-ext-tags
$(shell echo $(foreach cl,$(filter-out $1,$(shell seq $(CLUSTERS_NUMBER))),$(call nth-geo-tag,$(cl)))
	| sed 's/ /\\,/g')
endef

define get-helm-args
k8gb.clusterGeoTag='$(call nth-geo-tag,$1)' --set k8gb.extGslbClustersGeoTags='$(call get-ext-tags,$1)'
endef

define hit-testapp-host
	kubectl run -it --rm busybox --restart=Never --image=busybox --command \
	--overrides "{\"spec\":{\"dnsConfig\":{\"nameservers\":[\"$(shell $(K8GB_COREDNS_IP))\"]},\"dnsPolicy\":\"None\"}}" \
	-- wget -qO - $1
endef

define init-test-strategy
 	kubectl config use-context k3d-test-gslb2
 	kubectl apply -f $1
 	kubectl config use-context k3d-test-gslb1
 	kubectl apply -f $1
	$(MAKE) start-test-app

endef

define testapp-set-replicas
	kubectl scale deployment frontend-podinfo -n test-gslb --replicas=$1
endef

define demo-host
	kubectl run -it --rm k8gb-demo --restart=Never --image=absaoss/k8gb-demo-curl --env="DELAY=$(DEMO_DELAY)" --env="DEBUG=$(DEMO_DEBUG)" \
	"`$(K8GB_COREDNS_IP)`" $1
endef

# waits for NGINX, GSLB are ready
define wait-for-ingress
	kubectl -n k8gb wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx --timeout=600s
endef

define generate
	$(call install-controller-gen)
	@echo -e "\n$(YELLOW)Generating the API code$(NC)"
	$(GOBIN)/controller-gen object:headerFile="hack/boilerplate.go.txt" paths="./..."
endef

define crd-manifest
	$(call install-controller-gen)
	@echo -e "\n$(YELLOW)Generating the CRD manifests$(NC)"
	@echo -n "{{- if .Values.k8gb.deployCrds }}" > $(GSLB_CRD_YAML)
	$(GOBIN)/controller-gen crd:crdVersions=v1 paths="./..." output:crd:stdout >> $(GSLB_CRD_YAML)
	@echo "{{- end }}"  >> $(GSLB_CRD_YAML)
endef

define install-controller-gen
	@go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_GEN_VERSION)
endef

define gokart
	@go install github.com/praetorian-inc/gokart@$(GOKART_VERSION)
	$(GOBIN)/gokart scan $1
endef

define golic
	@go install github.com/AbsaOSS/golic@$(GOLIC_VERSION)
	$(GOBIN)/golic inject $1
endef

define debug
	$(call manifest)
	kubectl apply -f deploy/crds/test-namespace.yaml
	kubectl apply -f ./chart/k8gb/templates/k8gb.absa.oss_gslbs.yaml
	kubectl apply -f ./deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr.yaml
	dlv $1
endef

define deploy-prometheus
	echo -e "\n$(YELLOW)Local cluster $(CYAN)$1$(NC)" ;\
	echo -e "\n$(YELLOW)Set annotations on pods that will be scraped by prometheus$(NC)" ;\
	kubectl annotate pods -l name=k8gb -n k8gb --overwrite prometheus.io/scrape="true" --context=k3d-$1 ;\
	kubectl annotate pods -l name=k8gb -n k8gb --overwrite prometheus.io/port="8080" --context=k3d-$1 ;\
	echo -e "\n$(YELLOW)install prometheus $(NC)" ;\
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts ;\
	helm repo update ;\
	helm -n k8gb upgrade -i prometheus prometheus-community/prometheus -f deploy/prometheus/values.yaml \
		--version 14.2.0 \
		--wait --timeout=2m0s \
		--kube-context=k3d-$1
endef

define uninstall-prometheus
	echo -e "\n$(YELLOW)Local cluster $(CYAN)$1$(NC)" ;\
	echo -e "\n$(YELLOW)uninstall prometheus $(NC)" ;\
	helm uninstall prometheus -n k8gb --kube-context=k3d-$1 ;\
	kubectl annotate pods -l name=k8gb -n k8gb prometheus.io/scrape- --context=k3d-$1 ;\
	kubectl annotate pods -l name=k8gb -n k8gb prometheus.io/port- --context=k3d-$1
endef
