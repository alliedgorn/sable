#!/usr/bin/env python3
"""Google Workspace CLI for Drive, Docs, Sheets, and Slides.

Authentication: Uses a Google Cloud service account key (default: .secrets/service_account.json).
Override with --service-account /path/to/key.json

Usage examples:
  python scripts/google_workspace_cli.py whoami
  python scripts/google_workspace_cli.py drive-list --query "name contains 'Q1'"
  python scripts/google_workspace_cli.py sheet-create --title "P-006 Leadership Bootcamp Summary"
  python scripts/google_workspace_cli.py doc-append --document-id DOC_ID --text "Hello"
  python scripts/google_workspace_cli.py sheet-write --spreadsheet-id SHEET_ID --range "Sheet1!A1:B2" --values-json '[["A","B"],[1,2]]'
  python scripts/google_workspace_cli.py slide-replace-text --presentation-id PRES_ID --find-text "{{name}}" --replace-text "Alice"
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from google.oauth2.service_account import Credentials
from googleapiclient.discovery import build

SCOPES = [
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/documents",
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/presentations",
]

DEFAULT_SERVICE_ACCOUNT_PATH = Path(".secrets/service_account.json")


def _print_json(payload: Any) -> None:
    print(json.dumps(payload, indent=2, ensure_ascii=True))


def _parse_json(raw: str, label: str) -> Any:
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON for {label}: {exc}") from exc


def get_credentials(service_account_path: Path) -> Credentials:
    if not service_account_path.exists():
        raise SystemExit(
            f"Missing service account key: {service_account_path}. "
            "Create a service account in Google Cloud Console and save the JSON key there."
        )
    return Credentials.from_service_account_file(str(service_account_path), scopes=SCOPES)


def drive_service(creds: Credentials):
    return build("drive", "v3", credentials=creds)


def docs_service(creds: Credentials):
    return build("docs", "v1", credentials=creds)


def sheets_service(creds: Credentials):
    return build("sheets", "v4", credentials=creds)


def slides_service(creds: Credentials):
    return build("slides", "v1", credentials=creds)


def cmd_whoami(args: argparse.Namespace) -> None:
    creds = get_credentials(Path(args.service_account))
    service = drive_service(creds)
    about = service.about().get(fields="user,storageQuota").execute()
    _print_json(about)


def cmd_drive_list(args: argparse.Namespace) -> None:
    creds = get_credentials(Path(args.service_account))
    service = drive_service(creds)
    response = (
        service.files()
        .list(
            q=args.query,
            pageSize=args.page_size,
            fields="nextPageToken, files(id, name, mimeType, modifiedTime, owners(emailAddress), webViewLink)",
            orderBy=args.order_by,
            includeItemsFromAllDrives=True,
            supportsAllDrives=True,
        )
        .execute()
    )
    _print_json(response)


def cmd_drive_get(args: argparse.Namespace) -> None:
    creds = get_credentials(Path(args.service_account))
    service = drive_service(creds)
    file_meta = (
        service.files()
        .get(
            fileId=args.file_id,
            fields="id, name, mimeType, modifiedTime, owners(emailAddress), webViewLink, parents",
            supportsAllDrives=True,
        )
        .execute()
    )
    _print_json(file_meta)


def cmd_doc_append(args: argparse.Namespace) -> None:
    creds = get_credentials(Path(args.service_account))
    service = docs_service(creds)
    doc = service.documents().get(documentId=args.document_id).execute()
    end_index = doc.get("body", {}).get("content", [{}])[-1].get("endIndex", 1)

    text = args.text
    if args.newline:
        text += "\n"

    requests = [{"insertText": {"location": {"index": max(1, end_index - 1)}, "text": text}}]
    result = (
        service.documents()
        .batchUpdate(documentId=args.document_id, body={"requests": requests})
        .execute()
    )
    _print_json(result)


def _extract_doc_text(doc: dict[str, Any]) -> str:
    body = doc.get("body", {}).get("content", [])
    chunks: list[str] = []
    for structural in body:
        paragraph = structural.get("paragraph")
        if not paragraph:
            continue
        for element in paragraph.get("elements", []):
            text_run = element.get("textRun")
            if not text_run:
                continue
            content = text_run.get("content")
            if content:
                chunks.append(content)
    return "".join(chunks).strip()


def cmd_doc_read(args: argparse.Namespace) -> None:
    creds = get_credentials(Path(args.service_account))
    service = docs_service(creds)
    doc = service.documents().get(documentId=args.document_id).execute()
    if args.plain_text:
        text = _extract_doc_text(doc)
        payload = {
            "documentId": doc.get("documentId"),
            "title": doc.get("title"),
            "text": text,
        }
        _print_json(payload)
        return
    _print_json(doc)


def cmd_docs_batch(args: argparse.Namespace) -> None:
    creds = get_credentials(Path(args.service_account))
    service = docs_service(creds)
    requests = _parse_json(args.requests_json, "requests-json")
    if not isinstance(requests, list):
        raise SystemExit("requests-json must be a JSON array")

    result = (
        service.documents()
        .batchUpdate(documentId=args.document_id, body={"requests": requests})
        .execute()
    )
    _print_json(result)


def cmd_sheet_read(args: argparse.Namespace) -> None:
    creds = get_credentials(Path(args.service_account))
    service = sheets_service(creds)
    result = (
        service.spreadsheets()
        .values()
        .get(spreadsheetId=args.spreadsheet_id, range=args.range)
        .execute()
    )
    _print_json(result)


def cmd_sheet_create(args: argparse.Namespace) -> None:
    creds = get_credentials(Path(args.service_account))
    service = sheets_service(creds)
    body = {
        "properties": {"title": args.title},
        "sheets": [{"properties": {"title": args.sheet_name}}],
    }
    spreadsheet = service.spreadsheets().create(body=body).execute()
    sheet_id = spreadsheet.get("spreadsheetId")
    sheets = spreadsheet.get("sheets", [])
    payload = {
        "spreadsheetId": sheet_id,
        "title": spreadsheet.get("properties", {}).get("title"),
        "sheetName": sheets[0].get("properties", {}).get("title") if sheets else None,
        "webViewLink": f"https://docs.google.com/spreadsheets/d/{sheet_id}/edit",
    }
    _print_json(payload)


def cmd_sheet_write(args: argparse.Namespace) -> None:
    creds = get_credentials(Path(args.service_account))
    service = sheets_service(creds)
    values = _parse_json(args.values_json, "values-json")
    if not isinstance(values, list):
        raise SystemExit("values-json must be a JSON 2D array")

    result = (
        service.spreadsheets()
        .values()
        .update(
            spreadsheetId=args.spreadsheet_id,
            range=args.range,
            valueInputOption=args.input_option,
            body={"values": values},
        )
        .execute()
    )
    _print_json(result)


def cmd_sheets_batch(args: argparse.Namespace) -> None:
    creds = get_credentials(Path(args.service_account))
    service = sheets_service(creds)
    requests = _parse_json(args.requests_json, "requests-json")
    if not isinstance(requests, list):
        raise SystemExit("requests-json must be a JSON array")

    result = (
        service.spreadsheets()
        .batchUpdate(spreadsheetId=args.spreadsheet_id, body={"requests": requests})
        .execute()
    )
    _print_json(result)


def cmd_slide_replace_text(args: argparse.Namespace) -> None:
    creds = get_credentials(Path(args.service_account))
    service = slides_service(creds)
    requests = [
        {
            "replaceAllText": {
                "containsText": {
                    "text": args.find_text,
                    "matchCase": args.match_case,
                },
                "replaceText": args.replace_text,
            }
        }
    ]
    result = (
        service.presentations()
        .batchUpdate(presentationId=args.presentation_id, body={"requests": requests})
        .execute()
    )
    _print_json(result)


def cmd_slides_batch(args: argparse.Namespace) -> None:
    creds = get_credentials(Path(args.service_account))
    service = slides_service(creds)
    requests = _parse_json(args.requests_json, "requests-json")
    if not isinstance(requests, list):
        raise SystemExit("requests-json must be a JSON array")

    result = (
        service.presentations()
        .batchUpdate(presentationId=args.presentation_id, body={"requests": requests})
        .execute()
    )
    _print_json(result)


def cmd_slides_create(args: argparse.Namespace) -> None:
    creds = get_credentials(Path(args.service_account))
    service = slides_service(creds)
    presentation = service.presentations().create(body={"title": args.title}).execute()
    presentation_id = presentation.get("presentationId")
    slides = presentation.get("slides", [])
    payload = {
        "presentationId": presentation_id,
        "title": presentation.get("title"),
        "slidesCount": len(slides),
        "defaultSlideObjectId": slides[0].get("objectId") if slides else None,
        "webViewLink": f"https://docs.google.com/presentation/d/{presentation_id}/edit",
    }
    _print_json(payload)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Google Workspace CLI")
    parser.add_argument("--service-account", default=str(DEFAULT_SERVICE_ACCOUNT_PATH))

    subparsers = parser.add_subparsers(dest="command", required=True)

    whoami_parser = subparsers.add_parser("whoami", help="Show authenticated account info")
    whoami_parser.set_defaults(func=cmd_whoami)

    drive_list_parser = subparsers.add_parser("drive-list", help="List files in Drive")
    drive_list_parser.add_argument("--query", default=None)
    drive_list_parser.add_argument("--page-size", type=int, default=20)
    drive_list_parser.add_argument("--order-by", default="modifiedTime desc")
    drive_list_parser.set_defaults(func=cmd_drive_list)

    drive_get_parser = subparsers.add_parser("drive-get", help="Get Drive file metadata")
    drive_get_parser.add_argument("--file-id", required=True)
    drive_get_parser.set_defaults(func=cmd_drive_get)

    doc_append_parser = subparsers.add_parser("doc-append", help="Append text to a Google Doc")
    doc_append_parser.add_argument("--document-id", required=True)
    doc_append_parser.add_argument("--text", required=True)
    doc_append_parser.add_argument("--newline", action="store_true")
    doc_append_parser.set_defaults(func=cmd_doc_append)

    doc_read_parser = subparsers.add_parser("doc-read", help="Read a Google Doc")
    doc_read_parser.add_argument("--document-id", required=True)
    doc_read_parser.add_argument("--plain-text", action="store_true")
    doc_read_parser.set_defaults(func=cmd_doc_read)

    docs_batch_parser = subparsers.add_parser("docs-batch", help="Run docs.batchUpdate with requests JSON")
    docs_batch_parser.add_argument("--document-id", required=True)
    docs_batch_parser.add_argument("--requests-json", required=True)
    docs_batch_parser.set_defaults(func=cmd_docs_batch)

    sheet_read_parser = subparsers.add_parser("sheet-read", help="Read values from a Sheet range")
    sheet_read_parser.add_argument("--spreadsheet-id", required=True)
    sheet_read_parser.add_argument("--range", required=True)
    sheet_read_parser.set_defaults(func=cmd_sheet_read)

    sheet_create_parser = subparsers.add_parser("sheet-create", help="Create a new Google Sheet")
    sheet_create_parser.add_argument("--title", required=True)
    sheet_create_parser.add_argument("--sheet-name", default="Sheet1")
    sheet_create_parser.set_defaults(func=cmd_sheet_create)

    sheet_write_parser = subparsers.add_parser("sheet-write", help="Write values to a Sheet range")
    sheet_write_parser.add_argument("--spreadsheet-id", required=True)
    sheet_write_parser.add_argument("--range", required=True)
    sheet_write_parser.add_argument("--values-json", required=True)
    sheet_write_parser.add_argument("--input-option", default="USER_ENTERED", choices=["RAW", "USER_ENTERED"])
    sheet_write_parser.set_defaults(func=cmd_sheet_write)

    sheets_batch_parser = subparsers.add_parser("sheets-batch", help="Run sheets.batchUpdate with requests JSON")
    sheets_batch_parser.add_argument("--spreadsheet-id", required=True)
    sheets_batch_parser.add_argument("--requests-json", required=True)
    sheets_batch_parser.set_defaults(func=cmd_sheets_batch)

    slide_replace_parser = subparsers.add_parser("slide-replace-text", help="Replace text in Slides")
    slide_replace_parser.add_argument("--presentation-id", required=True)
    slide_replace_parser.add_argument("--find-text", required=True)
    slide_replace_parser.add_argument("--replace-text", required=True)
    slide_replace_parser.add_argument("--match-case", action="store_true")
    slide_replace_parser.set_defaults(func=cmd_slide_replace_text)

    slides_batch_parser = subparsers.add_parser("slides-batch", help="Run slides.batchUpdate with requests JSON")
    slides_batch_parser.add_argument("--presentation-id", required=True)
    slides_batch_parser.add_argument("--requests-json", required=True)
    slides_batch_parser.set_defaults(func=cmd_slides_batch)

    slides_create_parser = subparsers.add_parser("slides-create", help="Create a new Google Slides presentation")
    slides_create_parser.add_argument("--title", required=True)
    slides_create_parser.set_defaults(func=cmd_slides_create)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

