# src/media_toolkit/verifier.py
# sow: dt-media-vault-SOW-01
"""
Migration Verifier
"""

import click
import json
from pathlib import Path, PurePosixPath
from typing import List
from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn, BarColumn, TaskProgressColumn

from .utils.hash import verify_file_hash

console = Console()


class MigrationVerifier:
    """Verifies migration completeness"""
    
    def __init__(self, manifest_path: Path, target_root: Path):
        self.manifest_path = manifest_path
        self.target_root = Path(target_root)
        self.manifest = self._load_manifest()
        
        self.verified_count = 0
        self.missing_count = 0
        self.corrupted_count = 0
        self.expected_count = 0
        self.errors: List[str] = []
    
    def _load_manifest(self) -> dict:
        """Load migration manifest"""
        with open(self.manifest_path) as f:
            return json.load(f)
    
    def verify(self) -> bool:
        """Check every manifest entry; success never authorizes source cleanup."""
        self.verified_count = self.missing_count = self.corrupted_count = 0
        self.expected_count = 0
        self.errors.clear()
        try:
            if not self.target_root.is_dir() or self.target_root.is_symlink():
                raise ValueError("target root must be an existing ordinary directory")
            root = self.target_root.resolve(strict=True)
            if not isinstance(self.manifest, dict):
                raise ValueError("manifest must be an object")
            files_to_verify = self.manifest.get('files')
            if not isinstance(files_to_verify, list):
                raise ValueError("manifest files must be a list")
            self.expected_count = len(files_to_verify)
            declared_count = self.manifest.get('total_files')
            if type(declared_count) is not int or declared_count != self.expected_count:
                raise ValueError("manifest total_files does not match entry coverage")
        except (OSError, ValueError) as exc:
            self.errors.append(str(exc))
            console.print("[red]Verification incomplete: invalid root or manifest.[/red]")
            return False
        
        # Duplicate classification is a report, never permission to omit coverage.
        
        console.print(f"\n[bold blue]Verifying {len(files_to_verify):,} files...[/bold blue]")
        
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            BarColumn(),
            TaskProgressColumn(),
            console=console,
        ) as progress:
            
            task = progress.add_task("Verifying...", total=len(files_to_verify))
            
            for media_file in files_to_verify:
                try:
                    if not isinstance(media_file, dict):
                        raise ValueError("manifest entry must be an object")
                    relative = media_file['target_path']
                    if not isinstance(relative, str) or not relative:
                        raise ValueError("missing target path")
                    # Legacy manifests use one leading slash for root-relative paths.
                    relative = relative.removeprefix('/')
                    if (not relative or relative.startswith('/') or
                            any(part in {'', '.', '..'} for part in relative.split('/'))):
                        raise ValueError("target path must stay within its selected root")
                    target_path = root
                    for part in PurePosixPath(relative).parts:
                        target_path = target_path / part
                        if target_path.is_symlink():
                            raise ValueError("symlink target is not permitted")
                    expected_hash = media_file['hash']
                    if (not isinstance(expected_hash, str) or len(expected_hash) != 64 or
                            any(char not in '0123456789abcdef' for char in expected_hash)):
                        raise ValueError("manifest requires a BLAKE3 digest, not a preview")
                    if not target_path.exists():
                        self.missing_count += 1
                        error = f"Missing: {target_path}"
                        self.errors.append(error)
                        progress.update(task, advance=1)
                        continue
                    
                    if not target_path.is_file():
                        raise ValueError("target must be an ordinary file")
                    if not verify_file_hash(target_path, expected_hash):
                        self.corrupted_count += 1
                        error = f"Corrupted: {target_path}"
                        self.errors.append(error)
                        progress.update(task, advance=1)
                        continue
                    
                    self.verified_count += 1
                
                except Exception as e:
                    error = f"Entry verification error: {type(e).__name__}"
                    self.errors.append(error)
                
                progress.update(task, advance=1)
        
        console.print(f"\n[green]Verified: {self.verified_count:,}[/green]")
        console.print(f"[red]Missing: {self.missing_count:,}[/red]")
        console.print(f"[red]Corrupted: {self.corrupted_count:,}[/red]")
        
        complete = (not self.errors and self.missing_count == 0 and
                    self.corrupted_count == 0 and
                    self.verified_count == self.expected_count)
        if complete:
            if self.expected_count == 0:
                console.print("\nEmpty manifest: no files checked.")
            else:
                console.print(f"\n[green]Verified all {self.expected_count} manifest entries.[/green]")
        else:
            console.print("\n[bold red]Verification incomplete; preserve all source content.[/bold red]")
        return complete


@click.command()
@click.option('--manifest', required=True, type=click.Path(exists=True))
@click.option('--target', required=True, type=click.Path(exists=True))
def main(manifest: str, target: str):
    """Verify migration"""
    try:
        verifier = MigrationVerifier(Path(manifest), Path(target))
        if not verifier.verify():
            raise click.ClickException("verification incomplete")
    except (OSError, ValueError) as exc:
        raise click.ClickException("cannot verify manifest") from exc


if __name__ == '__main__':
    main()
