.PHONY: build push sqs build-test test

IMAGE_NAME := quay.io/app-sre/qontract-schemas
IMAGE_TEST := $(IMAGE_NAME)-test
IMAGE_TAG := $(shell git rev-parse --short=7 HEAD)
VALIDATOR_IMAGE := quay.io/redhat-services-prod/app-sre-tenant/qontract-validator-master/qontract-validator-master
VALIDATOR_IMAGE_TAG := latest
SERVER_IMAGE := quay.io/app-sre/qontract-server
SERVER_IMAGE_TAG := latest
CONTAINER_ENGINE ?= $(shell which podman >/dev/null 2>&1 && echo podman || echo docker)
OUTPUT_DIR ?= $(shell pwd)
OUTPUT_DIR := $(shell realpath $(OUTPUT_DIR))
BUNDLE_FILENAME ?= data.json
PWD := $(shell pwd)
GIT_COMMIT := $(shell git rev-parse HEAD)
GIT_COMMIT_TIMESTAMP := $(shell git log -1 --format=%ct $(GIT_COMMIT))
COMMIT_AUTHOR_EMAIL := $(shell git show -s --format='%ae' HEAD)

ifneq (,$(wildcard $(CURDIR)/.docker))
	DOCKER_CONF := $(CURDIR)/.docker
else
	DOCKER_CONF := $(HOME)/.docker
endif

help: ## Prints help for targets with comments
	@grep -E '^[a-zA-Z0-9.\ _-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

build:
	@docker build -t $(IMAGE_NAME):latest --target prod -f Dockerfile .
	@docker tag $(IMAGE_NAME):latest $(IMAGE_NAME):$(IMAGE_TAG)

push:
	@docker --config=$(DOCKER_CONF) push $(IMAGE_NAME):latest
	@docker --config=$(DOCKER_CONF) push $(IMAGE_NAME):$(IMAGE_TAG)

sqs:
	@AWS_ACCESS_KEY_ID=$(APP_INTERFACE_SQS_AWS_ACCESS_KEY_ID) \
	AWS_SECRET_ACCESS_KEY=$(APP_INTERFACE_SQS_AWS_SECRET_ACCESS_KEY) \
	AWS_REGION=$(APP_INTERFACE_SQS_AWS_REGION) \
	aws sqs send-message --queue-url $(APP_INTERFACE_SQS_QUEUE_URL) --message-body "{\"pr_type\": \"promote_qontract_schemas\", \"version\": \"$(IMAGE_TAG)\", \"author_email\": \"$(COMMIT_AUTHOR_EMAIL)\"}"

bundle: ## Use qontract-validator image to bundle schemas into $BUNDLE_FILENAME NOTE
	mkdir -p $(OUTPUT_DIR) fake_data fake_resources
	@$(CONTAINER_ENGINE) run --rm \
		-v $(PWD)/schemas:/schemas:z \
		-v $(PWD)/graphql-schemas:/graphql:z \
		-v $(PWD)/fake_data:/data:z \
		-v $(PWD)/fake_resources:/resources:z \
		$(VALIDATOR_IMAGE):$(VALIDATOR_IMAGE_TAG) \
		qontract-bundler /schemas /graphql/schema.yml /data /resources $(GIT_COMMIT) $(GIT_COMMIT_TIMESTAMP) > $(OUTPUT_DIR)/$(BUNDLE_FILENAME)
	rm -rf fake_data fake_resources

validate: ## Use qcontract-validator image to show any validation errors of schemas in $BUNDLE_FILENAME
	@$(CONTAINER_ENGINE) run --rm \
		-v $(OUTPUT_DIR):/bundle:z \
		$(VALIDATOR_IMAGE):$(VALIDATOR_IMAGE_TAG) \
		qontract-validator --only-errors /bundle/$(BUNDLE_FILENAME)

gql_validate: ## Run qontract-server with the schema bundle and no data to reveal any GQL schema issues
	@$(CONTAINER_ENGINE) run --rm \
		-v $(OUTPUT_DIR):/bundle:z \
		-p 4000:4000 \
		-e LOAD_METHOD=fs \
		-e DATAFILES_FILE=/bundle/$(BUNDLE_FILENAME) \
		$(SERVER_IMAGE):$(SERVER_IMAGE_TAG) \
		timeout 10 node ./dist/server.js || \
	if [ $$? -eq 124 ]; then exit 0; else exit $$?; fi;


build-test: clean
	@docker build -t $(IMAGE_TEST) --target test .

test: build-test
	@docker run --rm $(IMAGE_TEST)

clean:
	@rm -rf .tox .eggs *.egg-info buid .pytest_cache
	@find . -name "__pycache__" -type d -print0 | xargs -0 rm -rf
	@find . -name "*.pyc" -delete

bundle-and-validate-schema: bundle validate ## Same as successively running 'bundle' and 'validate'
