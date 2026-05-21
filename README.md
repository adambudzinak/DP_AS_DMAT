# Automation Scripts for Dynamic Malware Analysis Tools

Ansible automation that deploys two dynamic malware analysis sandboxes — CAPEv2
and Cuckoo3 — on Ubuntu end to end, with little manual setup.
 
Each wrapper drives the project's own official installation steps through
Ansible instead of replacing them, so the install logic stays intact and the
deployment can be repeated. The result is a practical way to stand up a sandbox
lab, meant for use by a faculty CSIRT team.
 
## Contents
 
- [`Automation_CAPEv2/`](./Automation_CAPEv2) — Ansible wrapper for automated CAPEv2 sandbox deployment on Ubuntu
- [`Automation_Cuckoo3/`](./Automation_Cuckoo3) — Ansible wrapper for automated Cuckoo3 sandbox deployment on Ubuntu
---
 
Developed as the practical part of the master's thesis **Tools for Dynamic
Malware Analysis** by Bc. Adam Budziňák at the Faculty of Electrical Engineering
and Information Technology, Slovak University of Technology in Bratislava.
