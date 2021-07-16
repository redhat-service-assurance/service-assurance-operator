FROM quay.io/openshift/origin-jenkins-agent-base:latest

COPY install-sdk.sh /install-sdk.sh
RUN ./install-sdk.sh
RUN pip3 install --upgrade pip && \
    pip3 install ansible && \
    ansible-galaxy collection install community.kubernetes && \
    pip3 install openshift
