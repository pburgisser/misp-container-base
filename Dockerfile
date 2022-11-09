FROM composer:2.1.14 as composer-build
ARG MISP_TAG
WORKDIR /tmp
ADD https://raw.githubusercontent.com/MISP/MISP/${MISP_TAG}/app/composer.json /tmp
RUN composer install --ignore-platform-reqs && \
    composer require jakub-onderka/openid-connect-php:1.0.0-rc1 supervisorphp/supervisor:^4.0 guzzlehttp/guzzle php-http/message lstrojny/fxmlrpc aws/aws-sdk-php --ignore-platform-reqs

FROM debian:bullseye-slim as php-build
RUN apt-get update; apt-get install -y --no-install-recommends \
    gcc \
    make \
    libfuzzy-dev \
    ca-certificates \
    php \
    php-dev \
    php-pear \
    librdkafka-dev \
    git \
    && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*
        
 RUN pecl channel-update pecl.php.net
 RUN cp "/usr/lib/$(gcc -dumpmachine)"/libfuzzy.* /usr/lib; pecl install ssdeep && pecl install rdkafka
 RUN git clone --recursive --depth=1 https://github.com/kjdev/php-ext-brotli.git && cd php-ext-brotli && phpize && ./configure && make && make install
        

FROM debian:bullseye-slim as python-build
RUN apt-get update; apt-get install -y --no-install-recommends \
    gcc \
    git \
    python3 \
    python3-dev \
    python3-pip \
    python3-setuptools \
    python3-wheel \
    libfuzzy-dev \
    libffi-dev \
    ca-certificates \
    && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

RUN mkdir /wheels

WORKDIR /tmp

RUN git clone --depth 1 https://github.com/CybOXProject/mixbox.git; \
    cd mixbox || exit; python3 setup.py bdist_wheel -d /wheels; \
    sed -i 's/-e //g' requirements.txt; pip3 wheel -r requirements.txt --no-cache-dir -w /wheels/

    # install python-maec
RUN git clone --depth 1 https://github.com/MAECProject/python-maec.git; \
    cd python-maec || exit; python3 setup.py bdist_wheel -d /wheels

    # install python-cybox
RUN git clone --depth 1 https://github.com/CybOXProject/python-cybox.git; \
    cd python-cybox || exit; python3 setup.py bdist_wheel -d /wheels; \
    sed -i 's/-e //g' requirements.txt; pip3 wheel -r requirements.txt --no-cache-dir -w /wheels/

    # install python stix
RUN git clone --depth 1 https://github.com/STIXProject/python-stix.git; \
    cd python-stix || exit; python3 setup.py bdist_wheel -d /wheels; \
    sed -i 's/-e //g' requirements.txt; pip3 wheel -r requirements.txt --no-cache-dir -w /wheels/

    # install STIX2.0 library to support STIX 2.0 export:
    # Original Requirements has a bunch of non-required pacakges, force it to only grab wheels for deps from setup.py
RUN git clone --depth 1 https://github.com/MISP/cti-python-stix2.git; \
    cd cti-python-stix2 || exit; python3 setup.py bdist_wheel -d /wheels; \
    echo "-e ." > requirements.txt; pip3 wheel -r requirements.txt --no-cache-dir -w /wheels/

    # install PyMISP
RUN git clone --depth 1 https://github.com/MISP/PyMISP.git; \
    cd PyMISP || exit; python3 setup.py bdist_wheel -d /wheels

    # install pydeep
RUN git clone --depth 1 https://github.com/coolacid/pydeep.git; \
    cd pydeep || exit; python3 setup.py bdist_wheel -d /wheels

    # Grab other modules we need
RUN pip3 wheel --no-cache-dir -w /wheels/ plyara pyzmq redis python-magic lief

# Remove extra packages due to incompatible requirements.txt files
WORKDIR /wheels
RUN find . -name "Sphinx*" | tee /dev/stderr | grep -v "Sphinx-1.5.5" | xargs rm -f


FROM debian:bullseye-slim
ENV DEBIAN_FRONTEND noninteractive
ARG MISP_TAG
ARG PHP_VER

# OS Packages
RUN apt-get update; apt-get install -y --no-install-recommends \
        # Requirements:
    procps \
    sudo \
    supervisor \
    git \
    cron \
    openssl \
    gpg-agent gpg \
    ssdeep \
    libfuzzy2 \
    mariadb-client \
    rsync \
    # Python Requirements
    python3 \
    python3-setuptools \
    python3-pip \
    # PHP Requirements
    php \
    php-apcu \
    php-curl \
    php-xml \
    php-intl \
    php-bcmath \
    php-mbstring \
    php-mysql \
    php-redis \
    php-gd \
    php-fpm \
    php-zip \
    librdkafka1 \
    libbrotli1 \
    # Unsure we need these
    zip unzip \
    wget \
    && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

RUN cd tmp && wget https://dlm.mariadb.com/1936386/Connectors/c/connector-c-3.2.5/mariadb-connector-c-3.2.5-debian-buster-amd64.tar.gz && \
    tar -xvzf mariadb-connector-c-3.2.5-debian-buster-amd64.tar.gz && cd mariadb-connector-c-3.2.5-debian-buster-amd64 && \
    mkdir /usr/lib/x86_64-linux-gnu/mariadb19 && mkdir /usr/lib/x86_64-linux-gnu/mariadb19/plugin && \
    cp /tmp/mariadb-connector-c-3.2.5-debian-buster-amd64/lib/mariadb/plugin/sha256_password.so /usr/lib/x86_64-linux-gnu/mariadb19/plugin/ && \
    rm -rf /tmp/mariadb-connector-c-3.2.5-debian-buster-amd64 && rm /tmp/mariadb-connector-c-3.2.5-debian-buster-amd64.tar.gz

# Python Modules
COPY --from=python-build /wheels /wheels
RUN pip3 install --no-cache-dir /wheels/*.whl && rm -rf /wheels

# PHP
# Install ssdeep prebuild, latest composer, then install the app's PHP deps
COPY --from=php-build /usr/lib/php/${PHP_VER}/ssdeep.so /usr/lib/php/${PHP_VER}/ssdeep.so
COPY --from=php-build /usr/lib/php/${PHP_VER}/rdkafka.so /usr/lib/php/${PHP_VER}/rdkafka.so
COPY --from=php-build /usr/lib/php/${PHP_VER}/brotli.so /usr/lib/php/${PHP_VER}/brotli.so

RUN mkdir -p /opt/MISP/libs
COPY --from=composer-build /tmp/Vendor /opt/MISP/libs/Vendor
COPY --from=composer-build /tmp/Plugin /opt/MISP/libs/Plugin
    
RUN for dir in /etc/php/*; do echo "extension=rdkafka.so" > "$dir/mods-available/rdkafka.ini"; done; phpenmod rdkafka
RUN for dir in /etc/php/*; do echo "extension=brotli.so" > "$dir/mods-available/brotli.ini"; done; phpenmod brotli

RUN for dir in /etc/php/*; do echo "extension=ssdeep.so" > "$dir/mods-available/ssdeep.ini"; done \
    ;phpenmod redis \
    ;phpenmod ssdeep