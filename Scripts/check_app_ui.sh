#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
python3 - <<'PY'
from pathlib import Path
import subprocess, tempfile
# Use SwiftPM's current link inputs; a wildcard may pick up stale objects from other branches.
bin_dir = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], text=True).strip())
objects = [p for p in (bin_dir/'CodexOrb.product/Objects.LinkFileList').read_text().splitlines()
           if '/CodexOrbCore.build/' in p]
checks = [
    ('commitment-bubble', ['AccountBadgeView.swift', 'CapsuleSurfaceStyle.swift', 'CapsuleGeometry.swift', 'OrbView.swift', 'OrbPanelController.swift', 'CommitmentBubble.swift', 'ResetCardsView.swift', 'ResetConfirmation.swift', 'QuotaDetailsView.swift', 'TokenDetailsView.swift'], 'check_commitment_bubble.swift'),
    ('appearance', ['AppSettings.swift', 'CLIUpdateController.swift', 'SettingsWindowController.swift', 'AccountBadgeView.swift', 'CapsuleSurfaceStyle.swift', 'CapsuleGeometry.swift', 'OrbView.swift', 'OrbPanelController.swift', 'CommitmentBubble.swift', 'ResetCardsView.swift', 'ResetConfirmation.swift', 'QuotaDetailsView.swift', 'TokenDetailsView.swift'], 'check_appearance.swift'),
    ('localization', ['AppSettings.swift', 'CLIUpdateController.swift', 'SettingsWindowController.swift', 'ResetCardsView.swift'], 'check_localization.swift'),
    ('account-badge', ['AccountBadgeView.swift', 'CapsuleSurfaceStyle.swift'], 'check_account_badge.swift'),
    ('account-badge-live', ['AccountBadgeView.swift', 'CapsuleSurfaceStyle.swift', 'CapsuleGeometry.swift', 'OrbView.swift', 'OrbPanelController.swift', 'CommitmentBubble.swift', 'ResetCardsView.swift', 'ResetConfirmation.swift', 'QuotaDetailsView.swift', 'TokenDetailsView.swift'], 'check_account_badge_live.swift'),
    ('popover', ['AccountBadgeView.swift', 'CapsuleSurfaceStyle.swift', 'CapsuleGeometry.swift', 'OrbView.swift', 'OrbPanelController.swift', 'CommitmentBubble.swift', 'ResetCardsView.swift', 'ResetConfirmation.swift', 'QuotaDetailsView.swift', 'TokenDetailsView.swift'], 'check_reset_popover.swift'),
    ('token-details', ['AccountBadgeView.swift', 'CapsuleSurfaceStyle.swift', 'CapsuleGeometry.swift', 'OrbView.swift', 'OrbPanelController.swift', 'CommitmentBubble.swift', 'ResetCardsView.swift', 'ResetConfirmation.swift', 'QuotaDetailsView.swift', 'TokenDetailsView.swift'], 'check_token_details_popover.swift'),
    ('reset', ['ResetCardsView.swift', 'ResetConfirmation.swift'], 'check_reset_cards.swift'),
    ('quota-forecast', ['QuotaDetailsView.swift'], 'check_quota_forecast.swift'),
    ('capsule', ['AccountBadgeView.swift', 'CapsuleSurfaceStyle.swift', 'CapsuleGeometry.swift', 'OrbView.swift', 'OrbPanelController.swift', 'CommitmentBubble.swift', 'ResetCardsView.swift', 'ResetConfirmation.swift', 'QuotaDetailsView.swift', 'TokenDetailsView.swift'], 'check_capsule_resize.swift'),
]
with tempfile.TemporaryDirectory(prefix='codexorb-ui-check-') as directory:
    for name, sources, check in checks:
        output = str(Path(directory)/name)
        subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-I', str(bin_dir/'Modules')]
            + [str(Path('Sources/CodexOrb')/s) for s in sources]
            + [str(Path('Scripts')/check)] + objects + ['-o', output], check=True)
        subprocess.run([output], check=True)
PY
