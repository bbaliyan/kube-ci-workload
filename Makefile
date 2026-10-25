# Every check lives here. The CI workflow only sets up the environment and
# calls a target, so a run on a laptop matches a run on GitHub.
#
# Run inside the kube-devenv image. Values arrive as Make variables:
#   BASE_REF  commit the branch started from; empty skips commit-messages
#
# test-integration is not part of test-commit. It installs the apps on a real cluster
# (KUBECONFIG) and needs kubectl, helm and jq on the PATH.

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

CHECKS   ?= /usr/share/kube-devenv/checks
BASE_REF ?= $(shell git rev-parse --verify --quiet origin/main)

SCRIPTS := $(shell git ls-files '*.sh') .githooks/pre-commit

.PHONY: test-commit test-fast test-integration hooks lint-scripts lint-yaml \
	lint-pipelines lint-renovate charts test-scripts secrets commit-messages

test-commit: test-fast lint-scripts lint-yaml lint-pipelines lint-renovate charts test-scripts commit-messages

test-fast: secrets

hooks:
	git config core.hooksPath .githooks

lint-scripts:
	bash -n $(SCRIPTS)
	shellcheck -S warning $(SCRIPTS)

lint-yaml:
	yamllint -d '{extends: relaxed, rules: {line-length: disable}}' bootstrap/values.yaml apps/*/values.yaml .gitlab-ci.yml .github/workflows

lint-pipelines:
	$(CHECKS)/pipeline-lint.sh .
	tests/check-gitlab-ci.sh

lint-renovate:
	python3 -c "import json; json.load(open('renovate.json'))"

# Lints and renders every chart, then validates the output against the Kubernetes and CRD schemas.
charts:
	helm repo add gitlab https://charts.gitlab.io --force-update >/dev/null
	$(CHECKS)/helm-kubeconform.sh .

test-scripts:
	tests/first-objects.sh

test-integration:
	tests/integration.sh

secrets:
	$(CHECKS)/secrets.sh .

commit-messages:
	REQUIRE_SIGNOFF=0 $(CHECKS)/commit-messages.sh "$(BASE_REF)"
