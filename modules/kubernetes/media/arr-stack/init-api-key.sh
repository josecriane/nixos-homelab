API_KEY=$(cat /secrets/api-key)
if [ ! -f /config/config.xml ]; then
  echo "Pre-seeding config.xml with stable API key..."
  cat > /config/config.xml <<XMLEOF
<Config>
  <ApiKey>${API_KEY}</ApiKey>
  <AnalyticsEnabled>False</AnalyticsEnabled>
</Config>
XMLEOF
  chown __PUID__:__PGID__ /config/config.xml
  echo "config.xml created with stable API key"
else
  CURRENT_KEY=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' /config/config.xml)
  if [ "$CURRENT_KEY" != "$API_KEY" ]; then
    echo "Updating API key in existing config.xml..."
    sed -i "s|<ApiKey>.*</ApiKey>|<ApiKey>${API_KEY}</ApiKey>|" /config/config.xml
    echo "API key updated"
  else
    echo "config.xml API key matches secret, no change needed"
  fi
fi
