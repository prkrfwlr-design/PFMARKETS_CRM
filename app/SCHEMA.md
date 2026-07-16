# CRM Data Schema

Plain reference for the fields in `data/clients.json`. Edit the JSON directly or through the app — both stay compatible.

## Client (a business you serve)

| Field | Meaning |
|---|---|
| `id` | Unique ID (e.g. CL-001). Don't reuse. |
| `business_name` | The client's business name. |
| `industry` | e.g. Pressure Washing. |
| `location` | City, state. |
| `status` | `Prospect`, `Active`, `Paused`, or `Lost`. |
| `services` | List of what you do for them: Cold Email, Website, Ad Management, CRM Access. |
| `contact_name` / `email` / `phone` / `website` | Main point of contact. |
| `monthly_value` | What they pay you per month (number). Drives the "Monthly Recurring" stat. |
| `start_date` | When they became a client. |
| `notes` | Free text. |
| `customers` | List of that client's own customers/leads (see below). |

## Customer (a client's customer or lead)

| Field | Meaning |
|---|---|
| `customer_id` | Unique ID (e.g. CU-0001). |
| `name` | Customer name. |
| `email` / `phone` / `address` | Contact info. |
| `stage` | `Lead`, `Quoted`, `Won`, `Customer`, or `Lost`. |
| `source` | How they came in: Cold Email, Referral, Ad, etc. |
| `job_type` | e.g. House Wash, Driveway, Roof. |
| `quote_value` | Dollar amount quoted (number). |
| `last_contact` | Date of last touch. |
| `notes` | Free text. |

## Why two levels

Your business has two layers: **you → your clients**, and **your clients → their customers**. Keeping customers nested inside each client means that when you add client logins later, each client's data is already cleanly separated — that's exactly the structure a multi-tenant portal needs.
