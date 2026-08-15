EXSVC.R4X
=========

EXSVC.R4X ist der Beispielservice fuer Service-Manager- und Endpoint-Tests.

Projektstruktur seit 0.51.19:
- `build.zig` baut den Service als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, Imports, Startdaten und Contract.

Build:

    cd Code\System\Services\ExampleService
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Services\ExampleService\zig-out\EXSVC.R4X

Contract:
- R4XStart-Entry: `exsvc_main`
- App-Klasse: `service`
- R4L-Imports: `R4SYS`
- Service-Name: `EXSVC`
- Standardargumente: `/RUN`
- Zielpfad im Image: `C:\R4OS\SERVICES\EXSVC.R4X`

