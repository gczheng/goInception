PROJECT=tidb
GOPATH ?= $(shell go env GOPATH)

# Ensure GOPATH is set before running build process.
ifeq "$(GOPATH)" ""
  $(error Please set the environment variable GOPATH before running `make`)
endif
FAIL_ON_STDOUT := awk '{ print } END { if (NR > 0) { exit 1 } }'

CURDIR := $(shell pwd)
path_to_add := $(addsuffix /bin,$(subst :,/bin:,$(GOPATH)))
export PATH := $(path_to_add):$(PATH)

GO        := go
GOBUILD   := CGO_ENABLED=0 $(GO) build $(BUILD_FLAG)
GOTEST    := CGO_ENABLED=1 $(GO) test -p 3
OVERALLS  := CGO_ENABLED=1 overalls
GOVERALLS := goveralls

ARCH      := "`uname -s`"
LINUX     := "Linux"
MAC       := "Darwin"
PACKAGE_LIST  := go list ./...| grep -vE "vendor"
PACKAGES  := $$($(PACKAGE_LIST))
PACKAGE_DIRECTORIES := $(PACKAGE_LIST) | sed 's|github.com/hanchuanchuan/$(PROJECT)/||'
FILES     := $$(find $$($(PACKAGE_DIRECTORIES)) -name "*.go" | grep -vE "vendor")

GOFAIL_ENABLE  := $$(find $$PWD/ -type d | grep -vE "(\.git|vendor)" | xargs gofail enable)
GOFAIL_DISABLE := $$(find $$PWD/ -type d | grep -vE "(\.git|vendor)" | xargs gofail disable)

LDFLAGS += -X "github.com/hanchuanchuan/goInception/mysql.TiDBReleaseVersion=$(shell git describe --tags --dirty)"
LDFLAGS += -X "github.com/hanchuanchuan/goInception/util/printer.TiDBBuildTS=$(shell date -u '+%Y-%m-%d %I:%M:%S')"
LDFLAGS += -X "github.com/hanchuanchuan/goInception/util/printer.TiDBGitHash=$(shell git rev-parse HEAD)"
LDFLAGS += -X "github.com/hanchuanchuan/goInception/util/printer.TiDBGitBranch=$(shell git rev-parse --abbrev-ref HEAD)"
LDFLAGS += -X "github.com/hanchuanchuan/goInception/util/printer.GoVersion=$(shell go version)"

TEST_LDFLAGS =  -X "github.com/hanchuanchuan/goInception/config.checkBeforeDropLDFlag=1"

CHECK_LDFLAGS += $(LDFLAGS) ${TEST_LDFLAGS}

TARGET = ""

.PHONY: all build update parser clean todo test gotest interpreter server dev benchkv benchraw check parserlib checklist

default: server buildsucc

server-admin-check: server_check buildsucc

buildsucc:
	@echo Build TiDB Server successfully!

all: dev server benchkv

dev: checklist parserlib test check

build:
	$(GOBUILD)

goyacc:
	$(GOBUILD) -o bin/goyacc parser/goyacc/main.go

parser: goyacc
	bin/goyacc -o /dev/null parser/parser.y
	bin/goyacc -o parser/parser.go parser/parser.y 2>&1 | egrep "(shift|reduce)/reduce" | awk '{print} END {if (NR > 0) {print "Find conflict in parser.y. Please check y.output for more information."; exit 1;}}'
	rm -f y.output

	@if [ $(ARCH) = $(LINUX) ]; \
	then \
		sed -i -e 's|//line.*||' -e 's/yyEofCode/yyEOFCode/' parser/parser.go; \
	elif [ $(ARCH) = $(MAC) ]; \
	then \
		/usr/bin/sed -i "" 's|//line.*||' parser/parser.go; \
		/usr/bin/sed -i "" 's/yyEofCode/yyEOFCode/' parser/parser.go; \
	fi

	@awk 'BEGIN{print "// Code generated by goyacc"} {print $0}' parser/parser.go > tmp_parser.go && mv tmp_parser.go parser/parser.go;

parserlib: parser/parser.go

parser/parser.go: parser/parser.y
	make parser

# The retool tools.json is setup from hack/retool-install.sh
check-setup:
	@which retool >/dev/null 2>&1 || go get github.com/twitchtv/retool
	@retool sync

check: check-setup fmt lint vet

# These need to be fixed before they can be ran regularly
check-fail: goword check-static check-slow

fmt:
	@echo "gofmt (simplify)"
	@gofmt -s -l -w $(FILES) 2>&1 | grep -v "vendor|parser/parser.go" | $(FAIL_ON_STDOUT)

goword:
	retool do goword $(FILES) 2>&1 | $(FAIL_ON_STDOUT)

check-static:
	@ # vet and fmt have problems with vendor when ran through metalinter
	CGO_ENABLED=0 retool do gometalinter.v2 --disable-all --deadline 120s \
	  --enable misspell \
	  --enable megacheck \
	  --enable ineffassign \
	  $$($(PACKAGE_DIRECTORIES))

check-slow:
	CGO_ENABLED=0 retool do gometalinter.v2 --disable-all \
	  --enable errcheck \
	  $$($(PACKAGE_DIRECTORIES))
	CGO_ENABLED=0 retool do gosec $$($(PACKAGE_DIRECTORIES))

lint:
	@echo "linting"
	@CGO_ENABLED=0 retool do revive -formatter friendly -config revive.toml $(PACKAGES)

vet:
	@echo "vet"
	@go vet -all -shadow $(PACKAGES) 2>&1 | $(FAIL_ON_STDOUT)

clean:
	$(GO) clean -i ./...
	rm -rf *.out

todo:
	@grep -n ^[[:space:]]*_[[:space:]]*=[[:space:]][[:alpha:]][[:alnum:]]* */*.go parser/parser.y || true
	@grep -n TODO */*.go parser/parser.y || true
	@grep -n BUG */*.go parser/parser.y || true
	@grep -n println */*.go parser/parser.y || true

test: checklist gotest explaintest

explaintest: server
	@cd cmd/explaintest && ./run-tests.sh -s ../../bin/tidb-server

gotest: parserlib
	go get github.com/etcd-io/gofail
	@$(GOFAIL_ENABLE)
ifeq ("$(TRAVIS_COVERAGE)", "1")
	@echo "Running in TRAVIS_COVERAGE mode."
	@export log_level=error; \
	go get github.com/go-playground/overalls
	go get github.com/mattn/goveralls
	$(OVERALLS) -project=github.com/hanchuanchuan/goInception -covermode=count -ignore='.git,vendor,cmd,docs,LICENSES' || { $(GOFAIL_DISABLE); exit 1; }
	$(GOVERALLS) -service=travis-ci -coverprofile=overalls.coverprofile || { $(GOFAIL_DISABLE); exit 1; }
else
	@echo "Running in native mode."
	@export log_level=error; \
	$(GOTEST) -ldflags '$(TEST_LDFLAGS)' -cover $(PACKAGES) || { $(GOFAIL_DISABLE); exit 1; }
endif
	@$(GOFAIL_DISABLE)

race: parserlib
	go get github.com/etcd-io/gofail
	@$(GOFAIL_ENABLE)
	@export log_level=debug; \
	$(GOTEST) -timeout 20m -race $(PACKAGES) || { $(GOFAIL_DISABLE); exit 1; }
	@$(GOFAIL_DISABLE)

leak: parserlib
	go get github.com/etcd-io/gofail
	@$(GOFAIL_ENABLE)
	@export log_level=debug; \
	$(GOTEST) -tags leak $(PACKAGES) || { $(GOFAIL_DISABLE); exit 1; }
	@$(GOFAIL_DISABLE)

tikv_integration_test: parserlib
	go get github.com/etcd-io/gofail
	@$(GOFAIL_ENABLE)
	$(GOTEST) ./store/tikv/. -with-tikv=true || { $(GOFAIL_DISABLE); exit 1; }
	@$(GOFAIL_DISABLE)

RACE_FLAG =
ifeq ("$(WITH_RACE)", "1")
	RACE_FLAG = -race
	GOBUILD   = GOPATH=$(GOPATH) CGO_ENABLED=1 $(GO) build
endif

CHECK_FLAG =
ifeq ("$(WITH_CHECK)", "1")
	CHECK_FLAG = $(TEST_LDFLAGS)
endif

server: parserlib
ifeq ($(TARGET), "")
	$(GOBUILD) $(RACE_FLAG) -ldflags '$(LDFLAGS) $(CHECK_FLAG)' -o bin/tidb-server tidb-server/main.go
else
	$(GOBUILD) $(RACE_FLAG) -ldflags '$(LDFLAGS) $(CHECK_FLAG)' -o '$(TARGET)' tidb-server/main.go
endif

server_check: parserlib
ifeq ($(TARGET), "")
	$(GOBUILD) $(RACE_FLAG) -ldflags '$(CHECK_LDFLAGS)' -o bin/tidb-server tidb-server/main.go
else
	$(GOBUILD) $(RACE_FLAG) -ldflags '$(CHECK_LDFLAGS)' -o '$(TARGET)' tidb-server/main.go
endif

benchkv:
	$(GOBUILD) -ldflags '$(LDFLAGS)' -o bin/benchkv cmd/benchkv/main.go

benchraw:
	$(GOBUILD) -ldflags '$(LDFLAGS)' -o bin/benchraw cmd/benchraw/main.go

benchdb:
	$(GOBUILD) -ldflags '$(LDFLAGS)' -o bin/benchdb cmd/benchdb/main.go

importer:
	$(GOBUILD) -ldflags '$(LDFLAGS)' -o bin/importer ./cmd/importer

update:
	which dep 2>/dev/null || go get -u github.com/golang/dep/cmd/dep
ifdef PKG
	dep ensure -add ${PKG}
else
	dep ensure -update
endif
	@echo "removing test files"
	dep prune
	bash ./hack/clean_vendor.sh

checklist:
	cat checklist.md

gofail-enable:
# Converting gofail failpoints...
	@$(GOFAIL_ENABLE)

gofail-disable:
# Restoring gofail failpoints...
	@$(GOFAIL_DISABLE)
