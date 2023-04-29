.PHONY: all

all: install test

clone:
	git clone https://github.com/invisirisk/pse-action /tmp/pa
install:
	npm cache clean --force
	npm install
test:
	npm run test


clean:
	rm -rf gettorbrowser
	rm -rf node_modules
	
