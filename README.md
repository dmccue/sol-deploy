# sol-deploy
solana deployment tool

```bash
# create ec2 asg and configure instances
ansible-playbook sol.yml
# delete asg and all ec2 resources
ansible-playbook sol.yml --tags delete
# reconfigure solana application on asg instances
ansible-playbook sol.yaml --tags application
```