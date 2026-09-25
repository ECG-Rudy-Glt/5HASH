### **Taylor Shift's Ticket Shop**

**Project Context:**

Group project of 3.

Taylor Shift's technical team has developed an e-commerce application for concert ticket sales. Your agency is responsible for deploying and configuring the infrastructure needed to host it and handle increased traffic when ticket sales begin.

**The Challenge:**

Deploy a scalable and reliable infrastructure for the existing application. The application is already developed, so your responsibility is limited to infrastructure deployment, server configuration, and documentation.

#### **Key Objectives:**

Infrastructure Deployment: Provision the infrastructure with Terraform.

Configuration Management: Configure the servers and deploy the application with Ansible.

Traffic Handling: Design the solution to remain available and responsive when traffic increases.

Documentation: Provide a concise README that allows the technical team to understand, operate, and maintain the solution.

#### Instructions:

**Infrastructure Deployment:**

Deploy the application using the generic PrestaShop image available on Docker Hub and connect it to a suitable database or data store.

Your solution must contain at least one EC2 instance provisioned with Terraform and configured with Ansible. It must also contain other relevant AWS resources.

You are free to decide which components run on EC2 and which use managed AWS services. For example, the application may run on EC2 with a managed database, or the database may run on EC2 while other components use AWS services. The completed architecture must work, support scaling, and be explained in the documentation.

**Traffic Handling:**

Explain how requests reach the application and how the proposed architecture handles increased traffic. You are free to choose the relevant AWS services and scaling strategy. Include the limits of your approach and describe what happens if an application instance becomes unavailable in your README.md and presentation

**Configuration Management:**

Use Ansible to configure the infrastructure provisioned by Terraform and deploy the application.

Your solution must use dynamic inventory with `cloud.terraform.terraform_provider`, reusable roles, Ansible Galaxy, Ansible Vault, templates, and handlers. Playbooks must be idempotent and must not contain plaintext secrets, private keys, or manually copied host addresses.

**Deliverables:**

Infrastructure Code: The Terraform code used to provision the infrastructure.

Configuration Code: The Ansible code used to configure the servers and deploy the application.

Documentation: A concise README that explains how to deploy, operate, and maintain the solution.

Presentation: A brief presentation covering the infrastructure choices, configuration management, and key considerations.

**Project Testing:**

The project will be tested using the commands below. You must document how to setup the backend for terraform state before the commands are run.

```sh

terraform -chdir=terraform init

terraform -chdir=terraform apply

ansible-galaxy install -r ansible/requirements.yml

ansible-inventory -i ansible/inventory.yml --graph

ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass

ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass

```

The second playbook run must report no unexpected changes. The evaluator will then access the documented application endpoint and verify its database or data-store connection.

#### Evaluation (30 pts)

Working solution (10 pts):

eCommerce application is deployed and reachable (3 pts)

Application is connected to a working database or data store (3 pts)

At least one EC2 instance is provisioned with Terraform and configured with Ansible (2 pts)

The complete solution can be deployed again from the submitted automation (2 pts)

Terraform and AWS infrastructure (7 pts):

Relevant AWS resources form a coherent architecture with a justified traffic-handling strategy (2 pts)

Code organisation, modules, variables, variable descriptions, and outputs (2 pts)

Environment separation (prod, staging, dev) (1 pt)

Remote state, locking, data sources, and resource references (1 pt)

Secure networking and secret handling (1 pt)

Ansible integration (6 pts):

Dynamic inventory generated from Terraform (2 pts)

Reusable roles and Ansible Galaxy (1 pt)

Ansible Vault and secure secret handling (1 pt)

Idempotent playbooks using templates and handlers (2 pts)

README for developers (4 pts):

Clarity and reproducible instructions (2 pts)

Briefness (1 pt)

Solution design choices, including the placement of components (1 pt)

Presentation (3 pts):

Clear explanation of the solution (1 pt)

Working demonstration (1 pt)

Ability to justify technical choices (1 pt)
