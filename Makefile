SHELL := /bin/bash

.PHONY: help aws-verify infra-build infra-synth infra-diff infra-deploy infra-up infra-down infra-status infra-update infra-destroy relay-test relay-build windows-check clean

help:
	@sed -n 's/^## //p' README.md

aws-verify:
	./scripts/aws-verify.sh

infra-build:
	./scripts/cdk.sh --version

infra-synth:
	./scripts/cdk.sh synth

infra-diff:
	./scripts/cdk.sh diff --no-change-set

infra-deploy:
	./scripts/infra-up.sh

infra-up:
	./scripts/infra-up.sh

infra-down:
	./scripts/infra-down.sh

infra-status:
	./scripts/infra-status.sh

infra-update:
	./scripts/infra-update.sh

infra-destroy:
	./scripts/infra-destroy.sh

relay-test:
	./scripts/relay-test.sh

relay-build:
	./scripts/relay-build.sh

windows-check:
	./scripts/windows-check.sh

clean:
	rm -rf infra/cdk.out dist
