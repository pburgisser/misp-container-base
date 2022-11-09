# Build 
## Base container
```
docker build --build-arg MISP_TAG=v2.4.162 --build-arg PHP_VER=20190902 -t misp-base:latest .
```