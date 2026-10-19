# STANAM POS local PostgreSQL setup

The local POS uses PostgreSQL for products, customer accounts, receipts, sale lines, payments, held sales, and module entries. It does not connect to or modify another POS database.

## Requirements

- PostgreSQL 18 installed and running on `127.0.0.1:5432`.
- The PostgreSQL `psql.exe` client at `C:\Program Files\PostgreSQL\18\bin\psql.exe`.
- A PostgreSQL role allowed to create a database (first run) and write to it.
- Windows PowerShell.

## First run

1. Double-click `setup-database.cmd`.
2. Enter the password for your PostgreSQL role at the PowerShell secure prompt. The password is used by that setup process only and is not saved in this project.
3. Double-click `start-pos.cmd` and enter the same PostgreSQL password again when prompted. The server creates a temporary super-admin login: username `admin`, password `admin2026`.
4. Open `http://127.0.0.1:8080/` in the browser. Keep the PowerShell server window open while using the POS.

If the POS server is already running, stop it with **Ctrl+C** and start it again so it can create the staff-account table and bootstrap the super-admin login. Existing product, customer, and sales data is retained. The temporary super-admin password must be changed immediately after signing in.

The default target is a new, isolated database named `stanam_pos`. To use another local host, port, database, or role, run either script from PowerShell with parameters, for example:

```powershell
.\setup-database.ps1 -HostName 127.0.0.1 -Port 5432 -Database stanam_pos -Username postgres
.\start-pos.ps1 -HostName 127.0.0.1 -Port 5432 -Database stanam_pos -Username postgres -WebPort 8080
```

## Data and security

The schema setup creates the POS tables and seeds a small hardware catalogue and customer list for evaluation. It is safe to rerun: existing products and customers are retained. Product stock decrements and payment records are committed with each completed sale in a single PostgreSQL transaction; held sales and module entries also survive a server restart.

Completed sales open an itemized tax invoice with customer details, line-level VAT, payment breakdown, and balance/change. Use **Print A4 top-half receipt** to print in portrait on A4 paper; the compact receipt is scaled as needed to keep it within the top half of the page. In the Epson L3250 print dialog, select **A4** paper and **Portrait** orientation, and disable browser headers and footers if they are enabled.

Counter workflows include receipt reprints, customer vehicle records, delivery and combined-delivery notes, quotations that can be loaded into checkout, catalogue/customer/receipt search, auditable correction and back-date requests, held-sale clearing, expense vouchers shared with the Expenses ledger, salesperson attribution, and staged-sale approvals. Staged drafts do not deduct stock or record payments until completed at the register. Approval decisions are stored separately from the original request; approving a back-date request does not rewrite a posted sale timestamp.

The Customers menu connects the customer directory and completed invoices to customer-account workflows. Administrators and managers can add signed, auditable opening balances and post credit/debit notes; credit accounts are also restricted to those roles. Receipt corrections are submitted as requests and reviewed separately without rewriting posted sales. Customer returns must reference an original receipt line and cannot exceed its unreturned quantity. Each return automatically creates a credit note at the original sale-line price; inspected saleable goods are restocked, while unsaleable goods are recorded without changing inventory.

The Products menu provides a live product list, saved catalogue categories, returnable empties tracked as stock items, a separate asset register, printable Code 39 barcode labels based on each product SKU, retail and wholesale price editing, monthly sales/quantity targets, and target analysis against completed sales. Retail price edits update the price used by counter checkout; empty-container items and categories appear in inventory and the POS catalogue. Restart the POS server after updating so startup applies the wholesale-price database migration and loads the matching API changes.

The Stock menu connects suppliers, opening balances, purchase orders, supplier GRNs, purchases reports, stock takes, initial stock, adjustments, transfers, and internal consumption to the product stock ledger. Posting a supplier GRN updates inventory and records its purchase order receipt in one database statement; stock takes check that the book quantity has not changed before reconciling. Supplier payable summaries include opening balances, recorded GRN purchases, and credit/debit notes, but do not yet track supplier payments. Mogogosiek and Koiwa currently share one stock quantity per product; transfers record dispatch and receipt in that shared pool rather than maintaining separate branch inventories. Restart the POS server after these updates so it loads the stock-movement endpoint and the latest database schema.

The physical shop locations are **Mogogosiek** and **Koiwa**. Select the active shop from the sidebar; administrators/managers can also choose it in **Settings → System Parameters**. The selection is saved on the current device, stored with each completed sale, and shown on the register and printed receipt. **Kericho** is part of the postal address (**P.O. Box 112, Kericho**), not a shop location. Inventory is shared between locations, and sales reports are not yet filtered by location.

The POS has database-backed **Admin**, **Manager**, **Cashier**, **Stock Controller**, and **Reports** access roles. Administrators add staff logins and assign roles from **Staff → Staff List**; **Staff → Access Roles** describes each role. Temporary staff passwords must be changed at first sign-in. Staff can change their own password from **Settings → My Password**; administrators can issue a temporary reset from **Staff → Change Staff Password**. Passwords are stored as salted PBKDF2-SHA256 hashes, and sign-in sessions expire after eight hours or when the server restarts. The built-in bootstrap password is intentionally temporary and must not be left in use.

Administrators can review release notes and the latest 500 successful changes under **Settings → Change Log** and **Settings → Audit Logs**. Audit entries record the staff account, action, affected area, and safe record references; passwords are never recorded. Under **Settings → Backups**, administrators can create and verify a manual PostgreSQL backup. The server also creates a verified custom-format backup every day at **17:00 local time** while the POS server is running. Backups are saved to `D:\STANAM POS Backups`; automatic backups older than **180 days** are removed, while manual backups are retained. Keep the POS server window running at the scheduled time. For an isolated restore trial, create a new PostgreSQL database and restore a `.dump` file into that database with `pg_restore`; restoring into an existing database can replace its data.

The app server binds to `127.0.0.1` only. PostgreSQL passwords are requested as secure terminal input and held in the server process environment for `psql`; they are not written to source files. The default `postgres` role is convenient for a local trial. For regular use, create a dedicated PostgreSQL role with access limited to `stanam_pos`.

This is a local POS prototype, not a hardened internet-facing service. It does not provide remote password recovery, multi-factor authentication, or protection against a local machine administrator. Do not expose the local HTTP server to an untrusted network, and back up the database regularly.
