# Contributing to the Clean Room NTFS Repair Project

Thank you for your interest in contributing to this open-source NTFS repair project! 

Because this project is built upon a strict **Clean Room (Chinese Wall) Reverse Engineering Methodology**, we must enforce rigorous legal guidelines for all code contributions. This ensures that the project remains completely free from intellectual property contamination and protects both the contributors and the project maintainers from potential legal disputes.

## 1. Contributor Eligibility Rules
To contribute code, architecture, or bug fixes to this project, you **MUST** meet the following criteria:
- You have **NEVER** had access to the source code of Microsoft Windows `chkdsk.exe`, NTFS.sys, or any related Microsoft proprietary filesystem drivers (e.g., through employment, leaked source code, or NDA agreements).
- You have **NEVER** reverse-engineered, disassembled, or decompiled Microsoft `chkdsk.exe` or any other proprietary third-party NTFS repair utilities.
- You agree to base your code implementations **exclusively** on the official `ntfs-repair_clean_room_spec.md` RFC provided in this repository, standard public NTFS documentation (such as Linux NTFS-3G wiki), and your own general programming knowledge.

*If you do not meet all of the above criteria, please do not submit Pull Requests to this repository.*

## 2. The Clean Room Barrier
You are acting as the **"Implementer"** on the clean side of the wall. 
You must not communicate with the original "Analyst" (the author of the RFC) regarding binary offsets, assembly instructions, or any proprietary implementation details that are not already abstracted in the English RFC document.

## 3. Required Contributor Certification (Developer Certificate of Origin)
To legally document the clean room status of every contribution, every Pull Request MUST include the following signed declaration in the PR description, or as a committed `CERTIFICATION.txt` file signed with your PGP key / GitHub verified signature.

By submitting a Pull Request, you explicitly agree to and sign the following statement:

> ### Clean Room Contributor Certification
> "I certify that I have never analyzed, disassembled, decompiled, or had access to the source code of Microsoft's `chkdsk` or any other proprietary NTFS repair utility. 
> 
> My implementation and code contributions are based solely on the public specification RFC provided in this repository, public NTFS documentation, and my personal understanding of data structures. 
>
> I understand that maintaining strict zero-contamination is vital to the legal integrity of this open-source project."
> 
> **Signed:** [Your Name / GitHub Handle]  
> **Date:** [YYYY-MM-DD]

## 4. Archiving of Certifications
The project maintainers will permanently archive these declarations alongside the commit history. This provides an irrefutable paper trail demonstrating that the codebase was developed independently by uncontaminated engineers, completely neutralizing any potential claims of copyright infringement by proprietary vendors.
