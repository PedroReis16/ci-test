# Build from repository root:
#   docker build -f docker-compose/dockerfiles/WebApi2.Dockerfile -t webapi2 .
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY Libraries/Models/Models.csproj Libraries/Models/
COPY Libraries/Database/Database.csproj Libraries/Database/
COPY WebApi2/WebApi2.csproj WebApi2/

RUN dotnet restore WebApi2/WebApi2.csproj

COPY Libraries/Models/ Libraries/Models/
COPY Libraries/Database/ Libraries/Database/
COPY WebApi2/ WebApi2/

RUN dotnet publish WebApi2/WebApi2.csproj -c Release -o /app/publish --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080

COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "WebApi2.dll"]
