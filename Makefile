SHELL := /bin/bash

# Do things in edx-platform
.PHONY: clean extract_translations help pull pull_translations push_translations requirements shell upgrade
.PHONY: api-docs docs guides swagger install-requirements

MKFILE_PATH := $(abspath $(lastword $(MAKEFILE_LIST)))
CURRENT_DIR := $(notdir $(patsubst %/,%,$(dir $(MKFILE_PATH))))

# Careful with mktemp syntax: it has to work on Mac and Ubuntu, which have differences.
PRIVATE_FILES := $(shell mktemp -u /tmp/private_files.XXXXXX)

help: ## display this help message
	@echo "Please use \`make <target>' where <target> is one of"
	@grep '^[a-zA-Z]' $(MAKEFILE_LIST) | sort | awk -F ':.*?## ' 'NF==2 {printf "\033[36m  %-25s\033[0m %s\n", $$1, $$2}'

clean: ## archive and delete most git-ignored files
	# Remove all the git-ignored stuff, but save and restore things marked
	# by start-noclean/end-noclean. Include Makefile in the tarball so that
	# there's always at least one file even if there are no private files.
	sed -n -e '/start-noclean/,/end-noclean/p' < .gitignore > /tmp/private-files
	-tar cf $(PRIVATE_FILES) Makefile `git ls-files --exclude-from=/tmp/private-files --ignored --others`
	-git clean -fdX
	tar xf $(PRIVATE_FILES)
	rm $(PRIVATE_FILES)

install-docker: ## Install docker
	sudo apt-get update
	sudo apt-get upgrade -y	
	sudo apt-get instal docker docker-compose
	sudo groupadd docker
	sudo usermod -aG docker ${USER}
	@read -t 10 -p "Hit ENTER or wait ten seconds to reboot(CTL+C to cancle)"
	sudo reboot

install-docker-buildx:
	docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
	docker buildx create --name cibuilder --driver docker-container --use
	docker buildx ls
	docker buildx inspect --bootstrap


ifndef ODOO_COMMIT_ID 
ODOO_COMMIT_ID:=15.0
endif

ifndef ${TAG}
TAG:=odoo15
endif

ifndef PLATFORM 
PLATFORM:=linux/amd64,linux/arm64
endif

docker-build: ## These make targets currently only build LMS images.
	@echo ${TAG} ${ODOO_COMMIT_ID} ${ODOO_SHA} ${PLATFORM}
	docker buildx build ./${TAG} -t telesoho/odoo:${TAG} --build-arg ODOO_COMMIT_ID=${ODOO_COMMIT_ID} --build-arg ODOO_SHA=${ODOO_SHA} --platform=${PLATFORM} --pull --push

docker-load:
	# docker buildx build ./${TAG} -t telesoho/odoo:${TAG} --build-arg ODOO_COMMIT_ID=${ODOO_COMMIT_ID} --build-arg ODOO_SHA=${ODOO_SHA} --platform=${PLATFORM} --pull --load


pull: ## update the Docker image used by "make shell"
	docker pull telesoho/${TAG}:latest

docker-auth: ## login docker
	echo "$$DOCKERHUB_PASSWORD" | docker login -u "$$DOCKERHUB_USERNAME" --password-stdin

docker-tag: docker_build
	docker tag telesoho/odoo telesoho/edx-platform:${GITHUB_SHA}
	docker tag telesoho/odoo:latest-newrelic openedx/edx-platform:${GITHUB_SHA}-newrelic


docker-push: docker-tag docker-auth ## push to docker hub
	docker push 'telesoho/odoo:latest'
	docker push "openedx/odoo:${GITHUB_SHA}"
	docker push 'openedx/odoo:latest-newrelic'
	docker push "openedx/odoo:${GITHUB_SHA}-newrelic"


SWAGGER = docs/swagger.yaml

docs: api-docs guides technical-docs ## build all the developer documentation for this repository

swagger: ## generate the swagger.yaml file
	DJANGO_SETTINGS_MODULE=docs.docs_settings python manage.py lms generate_swagger --generator-class=edx_api_doc_tools.ApiSchemaGenerator -o $(SWAGGER)

api-docs-sphinx: swagger	## generate the sphinx source files for api-docs
	rm -f docs/api/gen/*
	python docs/sw2sphinxopenapi.py $(SWAGGER) docs/api/gen

api-docs: api-docs-sphinx	## build the REST api docs
	cd docs/api; make html

technical-docs:  ## build the technical docs
	$(MAKE) -C docs/technical html

guides:	## build the developer guide docs
	cd docs/guides; make clean html

extract_translations: ## extract localizable strings from sources
	i18n_tool extract -v

push_translations: ## push source strings to Transifex for translation
	i18n_tool transifex push

pull_translations:  ## pull translations from Transifex
	git clean -fdX conf/locale
	i18n_tool transifex pull
	i18n_tool extract
	i18n_tool dummy
	i18n_tool generate
	git clean -fdX conf/locale/rtl
	git clean -fdX conf/locale/eo
	i18n_tool validate --verbose
	paver i18n_compilejs


detect_changed_source_translations: ## check if translation files are up-to-date
	i18n_tool changed


pre-requirements: ## install Python requirements for running pip-tools
	pip install -qr requirements/edx/pip-tools.txt

requirements: pre-requirements ## install development environment requirements
	# The "$(wildcard..)" is to include private.txt if it exists, and make no mention
	# of it if it does not.  Shell wildcarding can't do that with default options.
	pip-sync -q requirements/edx/development.txt $(wildcard requirements/edx/private.txt)

shell: ## launch a bash shell in a Docker container with all edx-platform dependencies installed
	docker run -it -e "NO_PYTHON_UNINSTALL=1" -e "PIP_INDEX_URL=https://pypi.python.org/simple" -e TERM \
	-v `pwd`:/edx/app/edxapp/edx-platform:cached \
	-v edxapp_lms_assets:/edx/var/edxapp/staticfiles/ \
	-v edxapp_node_modules:/edx/app/edxapp/edx-platform/node_modules \
	edxops/edxapp:latest /edx/app/edxapp/devstack.sh open

# Order is very important in this list: files must appear after everything they include!
REQ_FILES = \
	requirements/edx/pip-tools \
	requirements/edx/coverage \
	requirements/edx/doc \
	requirements/edx/paver \
	requirements/edx-sandbox/py35 \
	requirements/edx-sandbox/py38 \
	requirements/edx/base \
	requirements/edx/testing \
	requirements/edx/development \
	scripts/xblock/requirements

define COMMON_CONSTRAINTS_TEMP_COMMENT
# This is a temporary solution to override the real common_constraints.txt\n# In edx-lint, until the pyjwt constraint in edx-lint has been removed.\n# See BOM-2721 for more details.\n# Below is the copied and edited version of common_constraints\n
endef

COMMON_CONSTRAINTS_TXT=requirements/common_constraints.txt
.PHONY: $(COMMON_CONSTRAINTS_TXT)
$(COMMON_CONSTRAINTS_TXT):
	wget -O "$(@)" https://raw.githubusercontent.com/edx/edx-lint/master/edx_lint/files/common_constraints.txt || touch "$(@)"
	echo "$(COMMON_CONSTRAINTS_TEMP_COMMENT)" | cat - $(@) > temp && mv temp $(@)

compile-requirements: export CUSTOM_COMPILE_COMMAND=make upgrade
compile-requirements: $(COMMON_CONSTRAINTS_TXT) ## Re-compile *.in requirements to *.txt
	# This is a temporary solution to override the real common_constraints.txt
	# In edx-lint, until the pyjwt constraint in edx-lint has been removed.
	# See BOM-2721 for more details.
	sed 's/Django<2.3//g' requirements/common_constraints.txt > requirements/common_constraints.tmp
	mv requirements/common_constraints.tmp requirements/common_constraints.txt

	@ export REBUILD='--rebuild'; \
	for f in $(REQ_FILES); do \
		echo ; \
		echo "== $$f ===============================" ; \
		echo "pip-compile -v --no-emit-trusted-host --no-emit-index-url $$REBUILD ${COMPILE_OPTS} -o $$f.txt $$f.in"; \
		pip-compile -v --no-emit-trusted-host --no-emit-index-url $$REBUILD ${COMPILE_OPTS} -o $$f.txt $$f.in || exit 1; \
		export REBUILD=''; \
	done
	# Post process all of the files generated above to work around open pip-tools issues
	scripts/post-pip-compile.sh $(REQ_FILES:=.txt)
	# Let tox control the Django version for tests
	grep -e "^django==" requirements/edx/base.txt > requirements/edx/django.txt
	sed '/^[dD]jango==/d' requirements/edx/testing.txt > requirements/edx/testing.tmp
	mv requirements/edx/testing.tmp requirements/edx/testing.txt

upgrade: pre-requirements  ## update the pip requirements files to use the latest releases satisfying our constraints
	$(MAKE) compile-requirements COMPILE_OPTS="--upgrade"

check-types: ## run static type-checking tests
	mypy
