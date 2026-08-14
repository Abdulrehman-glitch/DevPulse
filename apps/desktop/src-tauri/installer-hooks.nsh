; Tauri's standard uninstaller checks a shortcut's target after removing the target
; executable. On Windows Server 2025 that probe can fail and leave the product-owned
; Desktop shortcut behind. Keep the standard uninstall flow and remove only this exact
; current-user shortcut in the supported post-uninstall hook.
!macro NSIS_HOOK_POSTUNINSTALL
  Delete "$DESKTOP\${PRODUCTNAME}.lnk"
  ; Non-recursive: removes the product folder only when the standard uninstaller
  ; already removed every shortcut and the directory is empty.
  RMDir "$SMPROGRAMS\${STARTMENUFOLDER}"
!macroend
