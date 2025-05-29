# Token Based Routing to Multiple OPW on the same host

Example of how to set up token based routing using an AWS ELB to OP Workers running on the same  host with Splunk Universal Forwarders sending traffic to the ELB.

## Log generation & Splunk UF

- Spin up 3 Ubuntu EC2 instances

### Log generation

On each server do the following:

- `mkdir /var/log/fakelogs/ /opt/fakelogs`
- Copy [fakelogs.sh](./fakelogs.sh) to `/opt/fakelogs`
- `vi /etc/logrotate.d/fakelogs`:

    ```
    /var/log/fakelogs/fakelog.log {
        hourly
        size 100M
        rotate 3
        copytruncate
        missingok
        notifempty
    }
    ```

- `chmod 644 /etc/logrotate.d/fakelogs`
- `chown root:root /etc/logrotate.d/fakelogs`
- `crontab -e`:

    ```
    # m h  dom mon dow   command
    * * * * * bash /opt/fakelogs/fakelogs.sh
    ```

### Splunk UF Setup

- [Install Splunk UF on each server](https://help.splunk.com/en/splunk-enterprise/forward-and-process-data/universal-forwarder-manual/9.4/install-the-universal-forwarder/install-a-nix-universal-forwarder#bfa92018_7238_476c_8351_2dd1ee65ef8c__Install_the_universal_forwarder_on_Linux):

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

- Create a directory for inputs: `mkdir -p $SPLUNK_HOME/etc/apps/fakelogs/default`
- `vi $SPLUNK_HOME/etc/apps/fakelogs/default/inputs.conf`

    ```
    host = kelnerhax-splunk-uf-1
    source = fakelogs

    [monitor:///var/log/fakelogs/fakelog.log]
    followTail = 1
    ```

- Assign owner/group: `chown -R splunkfwd:splunkfwd $SPLUNK_HOME/etc/apps/fakelogs`
- Restart splunk uf: `sudo $SPLUNK_HOME/bin/splunk restart`

We'll return later to configure out `outputs.conf` with our ELB address.

## Observability Pipelines

- Create 3 OP Pipelines (one for each token): https://app.datadoghq.com/observability-pipelines
- For simplicity sake use the log volume control template for each
- Select "Splunk TCP" as the source
- Select "Datadog Logs" as the destination
- Delete all processors except "Edit Fields"
- Set "Edit Fields" processor to "Add Field"
- Set "Filter Query" to `*`
- Set "Field to add" to `op_token`
- Set "Value to add" to `1111`, `2222`, and `3333` to differentiate between the 3 pipelines in the Datadog log explorer
- Click on "Next Install"
- Select your target platform (for this POC: Ubuntu)
- Input listener address of: `0.0.0.0:8282`
- Select an API key with RC enabled

Keep these pages open and move to the next section.
