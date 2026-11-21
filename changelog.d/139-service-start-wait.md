### Install

- macOS: `install` waits up to 30 seconds for MariaDB and Redis after `brew services start`, asking twice a second. It waited two seconds and then stopped with "redis did not come up" on a Mac where the first start took longer, although the service came up a moment later (#139).
