# sol-deploy
solana deployment tool

![Ansible Lint](https://github.com/dmccue/sol-deploy/workflows/Ansible%20Lint/badge.svg)

```bash
# create ec2 asg and configure instances
ansible-playbook sol.yml
# delete asg and all ec2 resources
ansible-playbook sol.yml --tags delete
# reconfigure solana application on asg instances
ansible-playbook sol.yaml --tags application
```