import Fleet

/-- Export only the public identity/ACL declaration for integration checking. -/
def main : IO Unit := IO.print vaultServiceIdentities
