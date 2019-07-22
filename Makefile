TODAY := $(shell date -u +'%Y.%m.%d')
# Use the latest alpha RabbitMQ 3.8 release - https://dl.bintray.com/rabbitmq/all-dev/rabbitmq-server/
BASED_ON_RABBITMQ_VERSION := 3.8.0-alpha.735
DOCKER_IMAGE_NAME := pivotalrabbitmq/rabbitmq-prometheus
DOCKER_IMAGE_VERSION := $(BASED_ON_RABBITMQ_VERSION)-$(TODAY)
# RABBITMQ_VERSION is used in rabbitmq-components.mk to set PROJECT_VERSION
RABBITMQ_VERSION ?= $(DOCKER_IMAGE_VERSION)

PROJECT := rabbitmq_prometheus
PROJECT_MOD := rabbit_prometheus_app
DEPS = rabbit rabbitmq_management_agent prometheus rabbitmq_web_dispatch
# Deps that are not applications
# rabbitmq_management is added so that we build a custom version, for the Docker image
BUILD_DEPS = accept amqp_client rabbit_common rabbitmq_management
TEST_DEPS = rabbitmq_ct_helpers rabbitmq_ct_client_helpers eunit_formatters

EUNIT_OPTS = no_tty, {report, {eunit_progress, [colored, profile]}}

DEP_EARLY_PLUGINS = rabbit_common/mk/rabbitmq-early-plugin.mk
DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk

# FIXME: Use erlang.mk patched for RabbitMQ, while waiting for PRs to be
# reviewed and merged.

ERLANG_MK_REPO = https://github.com/rabbitmq/erlang.mk.git
ERLANG_MK_COMMIT = rabbitmq-tmp

ifneq ($(DISABLE_METRICS_COLLECTOR),)
BUILD_DEPS = accept amqp_client rabbit_common
RABBITMQ_CONFIG_FILE = $(CURDIR)/rabbitmq-disable-metrics-collector.conf
export RABBITMQ_CONFIG_FILE
endif

include rabbitmq-components.mk
include erlang.mk

.PHONY: docker_login
docker_login:
	@echo "$$(lpass show --password 7672183166535202820)" | \
	docker login --username pivotalrabbitmq --password-stdin
.PHONY: dl
dl: docker_login

.PHONY: docker_image
docker_image: docker_image_build docker_image_push
.PHONY: di
di: docker_image

.PHONY: docker_image_build
docker_image_build:
	@docker build --pull \
	  --build-arg PGP_KEYSERVER=pgpkeys.eu \
	  --build-arg RABBITMQ_VERSION=$(BASED_ON_RABBITMQ_VERSION) \
	  --build-arg RABBITMQ_PROMETHEUS_VERSION=$(RABBITMQ_VERSION) \
	  --tag $(DOCKER_IMAGE_NAME):$(DOCKER_IMAGE_VERSION) \
	  --tag $(DOCKER_IMAGE_NAME):latest .
.PHONY: dib
dib: docker_image_build

.PHONY: docker_image_push
docker_image_push:
	@docker push $(DOCKER_IMAGE_NAME):$(DOCKER_IMAGE_VERSION) && \
	docker push $(DOCKER_IMAGE_NAME):latest
.PHONY: dip
dip: docker_image_push

.PHONY: docker_image_run
docker_image_run:
	@docker run --interactive --tty \
	  --publish=5672:5672 \
	  --publish=15672:15672 \
	  --publish=15692:15692 \
	  $(DOCKER_IMAGE_NAME):$(DOCKER_IMAGE_VERSION)
.PHONY: dir
dir: docker_image_run

.PHONY: docker_image_version_bump
docker_image_version_bump:
	@sed -i '' \
	  -e 's|$(DOCKER_IMAGE_NAME):.*|$(DOCKER_IMAGE_NAME):$(DOCKER_IMAGE_VERSION)|g' \
	  -e 's|pivotalrabbitmq/perf-test:.*|pivotalrabbitmq/perf-test:dev-2019.07.18|g' \
	  docker/docker-compose-{overview,dist-tls,qq}.yml
.PHONY: divb
divb: docker_image_version_bump


define CTOP_CONTAINER
docker pull quay.io/vektorlab/ctop:latest && \
docker run --rm --interactive --tty \
  --cpus 0.5 --memory 128M \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --name ctop_$(USER) \
  quay.io/vektorlab/ctop:latest
endef
.PHONY: ctop
ctop:
	@$(CTOP_CONTAINER)

JQ := /usr/local/bin/jq
$(JQ):
	@brew install jq

OTP_CURRENT_STABLE_MAJOR := 22
define LATEST_STABLE_OTP_VERSION
curl --silent --fail https://api.github.com/repos/erlang/otp/git/refs/tags | \
  $(JQ) -r '.[].ref | sub("refs/tags/OTP.{1}";"") | match("^$(OTP_CURRENT_STABLE_MAJOR)[0-9.]+$$") | .string' | \
  tail -n 1
endef
define LATEST_STABLE_OTP_SHA256
c14aebda6afae82809325c18d51a66e618b3f237b856080a7d8f4b5bb089e758
endef
.PHONY: find_latest_otp
find_latest_otp: $(JQ)
	@printf "Version: " && \
	export VERSION="$$($(LATEST_STABLE_OTP_VERSION))" && \
	echo "$$VERSION" && \
	printf "Checksum: " && \
	wget --continue --quiet --output-document="/tmp/OTP-$$VERSION.tar.gz" "https://github.com/erlang/otp/archive/OTP-$$VERSION.tar.gz" && \
	shasum -a 256 "/tmp/OTP-$$VERSION.tar.gz"
.PHONY: flo
flo: find_latest_otp

DOCKER_COMPOSE_ACTION ?= up --detach && docker-compose --file $(@F) logs --follow
DOCKER_COMPOSE_FILES := $(wildcard docker/docker-compose-*.yml)
.PHONY: $(DOCKER_COMPOSE_FILES)
$(DOCKER_COMPOSE_FILES):
	@cd docker && \
	docker-compose --file $(@F) $(DOCKER_COMPOSE_ACTION) ; \
	true
.PHONY: down
down: DOCKER_COMPOSE_ACTION = down
down: $(DOCKER_COMPOSE_FILES)

define DOCKER_COMPOSE_UP
cd docker && \
docker-compose --file docker-compose-$(@F).yml up --detach
endef
.PHONY: metrics overview dist-tls qq
metrics overview dist-tls qq:
	@$(DOCKER_COMPOSE_UP)

.PHONY: up
up: DOCKER_COMPOSE_ACTION = up --detach
up: $(DOCKER_COMPOSE_FILES)

DASHBOARDS_FROM_PATH := $(HOME)/Downloads
DASHBOARDS_TO_PATH := $(CURDIR)/docker/grafana/dashboards
.PHONY: update_dashboards
update_dashboards:
	mv -fv $(DASHBOARDS_FROM_PATH)/RabbitMQ-Overview-*.json $(DASHBOARDS_TO_PATH)/RabbitMQ-Overview.json ; \
	mv -fv $(DASHBOARDS_FROM_PATH)/RabbitMQ-Raft-*.json $(DASHBOARDS_TO_PATH)/RabbitMQ-Raft.json ; \
	mv -fv $(DASHBOARDS_FROM_PATH)/Erlang-Distribution-*.json $(DASHBOARDS_TO_PATH)/Erlang-Distribution.json ; \
	mv -fv $(DASHBOARDS_FROM_PATH)/Erlang-Memory-Allocators-*.json $(DASHBOARDS_TO_PATH)/Erlang-Memory-Allocators.json ; \
	true
.PHONY: ud
ud: update_dashboards

.PHONY: clean_docker
clean_docker:
	@docker system prune -f && \
	docker volume prune -f
.PHONY: cd
cd: clean_docker
