# Build from repository root:
#   docker build -f docker-compose/dockerfiles/WebApi1.Dockerfile -t webapi1 .
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY Libraries/Models/Models.csproj Libraries/Models/
COPY Libraries/Database/Database.csproj Libraries/Database/
COPY WebApi1/WebApi1.csproj WebApi1/

RUN dotnet restore WebApi1/WebApi1.csproj

COPY Libraries/Models/ Libraries/Models/
COPY Libraries/Database/ Libraries/Database/
COPY WebApi1/ WebApi1/

RUN dotnet publish WebApi1/WebApi1.csproj -c Release -o /app/publish --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080

COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "WebApi1.dll"]
