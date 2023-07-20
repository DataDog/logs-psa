#!/usr/bin/env python

import time
from faker import Faker
import random
from syslog import syslog
import json

fake = Faker()

i = 1
while i < 60:
    messages = [
        "transferring money to bank account: " + fake.iban(),
        "charging CC: " + fake.credit_card_number(),
        "querying credit score for SSN: " + fake.ssn(),
    ]
    log = {
        "source": "python",
        "tags": "env:prod, version:5.1, kelner:hax",
        "hostname": "i-02a4fd78aa35b",
        "message": random.choice(messages),
        "service": "charge-back",
    }
    syslog(json.dumps(log))
    i += 1
    time.sleep(1)
