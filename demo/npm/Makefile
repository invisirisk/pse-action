.PHONY: all

all: clone install test

clone:
	git clone https://github.com/TheTorProject/gettorbrowser
install:
	npm cache clean --force
	npm install
test:
	npm run test


clean:
	rm -rf gettorbrowser
	rm -rf node_modules
	