build:
	docker build --build-arg MISP_TAG=v2.4.167 --build-arg PHP_VER=20190902 -t misp-base:dev .