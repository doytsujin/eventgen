VERSION := `grep '^__version__[^"]*"\([0-9.]*\)"' splunk_eventgen/__init__.py | sed -e 's/.*"\([0-9.]*\)".*/\1/'`
EVENTGEN_EGG := "dist/splunk_eventgen-${VERSION}.tar.gz"
EVENTGEN_TAG := "sa-eventgen"
CURTIME ?= $(shell date +%s)
EVENTGEN_TEST_IMAGE = "eventgen-test-container"
TESTS ?= large
TEST_ARGS += ${TESTS}
ENGINE_CONF_SOURCE ?= "https://repo.splunk.com/artifactory/Solutions/Common/misc/eventgen_engine.conf"
SMALL ?= 'tests/small'
MEDIUM ?= 'tests/medium'
LARGE ?= 'tests/large'
XLARGE ?= 'tests/xlarge'

.PHONY: tests

all: egg

egg: clean
	python setup.py sdist

push_egg_production:
	python setup.py sdist upload -r production

image: setup_eventgen egg
	cp dist/splunk_eventgen-*.tar.gz dockerfiles/splunk_eventgen.tgz
	rm splunk_eventgen/default/eventgen_engine.conf || true
	cd dockerfiles && docker build . -t eventgen

push_image_production: image
	docker tag eventgen:latest repo.splunk.com/splunk/products/eventgenx:latest
	docker push repo.splunk.com/splunk/products/eventgenx:latest

test: egg test_helper test_collection_cleanup

test_helper:
	docker run -d -t --net=host -v /var/run/docker.sock:/var/run/docker.sock --name ${EVENTGEN_TEST_IMAGE} python:2.7.14-alpine3.6 cat

	@echo 'Creating dirs needed for tests'
	docker exec -i ${EVENTGEN_TEST_IMAGE} /bin/sh -c "mkdir -p $(shell pwd) "

	@echo 'Copying orca tree into the orca container'
	docker cp . ${EVENTGEN_TEST_IMAGE}:$(shell pwd)

	@echo 'Verifying contents of pip.conf'
	docker exec -i ${EVENTGEN_TEST_IMAGE} /bin/sh -c "cd $(shell pwd); pip install dist/splunk_eventgen*.tar.gz"

	@echo 'Installing test requirements'
	docker exec -i ${EVENTGEN_TEST_IMAGE} /bin/sh -c "pip install -r $(shell pwd)/tests/requirements.txt"

	@echo 'Running the super awesome tests'
	#docker exec -i ${EVENTGEN_TEST_IMAGE} /bin/sh -c "cd $(shell pwd); pytest tests/ --junitxml tests_results.xml"

	docker exec -i ${EVENTGEN_TEST_IMAGE} /bin/sh -c "cd $(shell pwd); python tests/run_tests.py ${SMALL} ${MEDIUM} ${LARGE} ${XLARGE}"

	echo 'Collecting results'
	#TODO: Should be paramaterized or generalized so that we don't need to add this here
	docker cp ${EVENTGEN_TEST_IMAGE}:$(shell pwd)/tests_results.xml tests_results.xml || echo "no tests_results.xml"

	docker stop ${EVENTGEN_TEST_IMAGE} || true

test_collection_cleanup:
	@echo 'Collecting results'
	#TODO: Should be paramaterized or generalized so that we don't need to add this here
	docker cp ${EVENTGEN_TEST_IMAGE}:$(shell pwd)/tests_out.xml tests_out.xml || echo "no tests_out.xml"
	docker cp ${EVENTGEN_TEST_IMAGE}:$(shell pwd)/tests_medium_results.xml tests_medium_results.xml || echo "no tests_medium_results.xml"
	docker cp ${EVENTGEN_TEST_IMAGE}:$(shell pwd)/tests_large_results.xml tests_large_results.xml || echo "no tests_large_results.xml"
	docker cp ${EVENTGEN_TEST_IMAGE}:$(shell pwd)/tests_xlarge_results.xml tests_xlarge_results.xml || echo "no tests_xlarge_results.xml"
	docker cp ${EVENTGEN_TEST_IMAGE}:$(shell pwd)/tests/functional_orca_test.log functional_orca_test.log || echo "no functional_orca_test.log"

	@echo 'Stopping test container'
	docker stop ${EVENTGEN_TEST_IMAGE}

clean:
	rm -rf dist *.egg-info *.log *.xml
	docker stop ${EVENTGEN_TEST_IMAGE} || true
	docker rm ${EVENTGEN_TEST_IMAGE} || true

setup_eventgen:
	wget -O splunk_eventgen/default/eventgen_engine.conf ${ENGINE_CONF_SOURCE}

eg_network:
	docker network create --attachable --driver bridge eg_network || true

run_server: eg_network
	docker kill eg_server || true
	docker rm eg_server || true
	docker run --network eg_network --name eg_server -e EVENTGEN_AMQP_HOST="eg_controller" -d -p 9500 eventgen:latest server

run_controller: eg_network
	docker kill eg_controller || true
	docker rm eg_controller || true
	docker run --name eg_controller --network eg_network -d -p 5672 -p 15672 -p 9500 eventgen:latest controller

docs:
	docker build -t stg-repo.splunk.com/tonyl/eventgen-docs:latest documentation/
	docker push stg-repo.splunk.com/tonyl/eventgen-docs:latest
	python documentation/deploy.py --certs ~/.orca
