# Token Based Routing to Multiple OPW on the same host

Example of how to set up token based routing using an AWS ELB to OP Workers running on the same  host with Splunk Universal Forwarders sending traffic to the ELB.

## Log generation & Splunk UF

- Spin up 3 EC2 instances

### Splunk UF Setup

[Install Splunk UF on each instance](https://help.splunk.com/en/splunk-enterprise/forward-and-process-data/universal-forwarder-manual/9.4/install-the-universal-forwarder/install-a-nix-universal-forwarder#bfa92018_7238_476c_8351_2dd1ee65ef8c__Install_the_universal_forwarder_on_Linux):

    ```bash
    useradd -m splunkfwd
    export SPLUNK_HOME="/opt/splunkforwarder"
    cd $SPLUNK_HOME
    wget -O splunkforwarder-9.4.2-e9664af3d956-linux-amd64.deb "https://download.splunk.com/products/universalforwarder/releases/9.4.2/linux/splunkforwarder-9.4.2-e9664af3d956-linux-amd64.deb"
    dpkg -i splunkforwarder-9.4.2-e9664af3d956-linux-amd64.deb
    chown -R splunkfwd:splunkfwd $SPLUNK_HOME
    sudo $SPLUNK_HOME/bin/splunk start --accept-license
    # create admin username & password at prompts
    ```
