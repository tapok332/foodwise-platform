#!/usr/bin/env bash
# Seed FoodWise dev database with 10 items per business table via REST API.
#
# Idempotency strategy: every email/title carries a $TS suffix, so re-runs do
# not collide on unique constraints (and they grow the dataset, which is what
# you want in a dev environment).
#
# Auth model:
#   * /auth/register defaults the new user to role CLIENT (see fw-auth-service
#     AuthService.register, fw-common Role enum).
#   * Admin endpoints (categories, stores, promos, ...) currently sit on
#     PUBLIC_PATHS in fw-gateway, so the gateway does not strip the bearer
#     header and downstream services have no @PreAuthorize check yet. We still
#     promote one user to ADMIN and send "Authorization: Bearer <jwt>" so this
#     script keeps working when Wave 3 lands @PreAuthorize("hasRole('ADMIN')").
#   * Promotion = direct UPDATE on users.authorities jsonb (which is the
#     source of truth - user_roles table is created but unused) followed by
#     a re-login to mint a JWT that carries the ADMIN role claim.
#
# Required env (with sane defaults):
#   GATEWAY  default http://localhost:8080
#   POSTGRES_USER, POSTGRES_PASSWORD  forwarded into docker compose for psql
set -euo pipefail

# ---------- prerequisites ----------
GATEWAY="${GATEWAY:-http://localhost:8080}"
PG_SUPER_USER="${POSTGRES_USER:-postgres}"
TS=$(date +%s)

require() { command -v "$1" >/dev/null 2>&1 || { echo "Need $1 in PATH"; exit 1; }; }
require curl
require jq
require docker

KYIV_LAT_BASE="50.40"
KYIV_LNG_BASE="30.40"

run_psql() {
  local db="$1"; shift
  docker compose exec -T -e PGPASSWORD="${POSTGRES_PASSWORD:-postgres}" \
    postgres psql -v ON_ERROR_STOP=1 -U "$PG_SUPER_USER" -d "$db" "$@"
}

# Auth endpoints return a bare JwtResponse; everything else wraps in ApiResponse{success,data,error}.
extract_id()    { jq -r '.data.id // .id'; }
extract_token() { jq -r '.accessToken.tokenValue'; }

# ---------- phase 1: admin user ----------
echo ">> phase 1: register + promote admin"
ADMIN_EMAIL="seed-admin-${TS}@foodwise.local"
ADMIN_PASSWORD="AdminP@ss123"

curl -fsS -X POST "$GATEWAY/auth/register" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" \
        '{email:$e, password:$p, name:"Seed Admin"}')" \
  >/dev/null

run_psql foodwise_auth -c \
  "UPDATE users SET authorities = '{\"grants\":[],\"roles\":[\"ADMIN\"]}'::jsonb \
   WHERE email = '$ADMIN_EMAIL';" >/dev/null

ADMIN_TOKEN=$(curl -fsS -X POST "$GATEWAY/auth/login" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" \
        '{email:$e, password:$p}')" \
  | extract_token)

if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
  echo "Admin login failed - aborting."
  exit 1
fi
ADM=(-H "Authorization: Bearer $ADMIN_TOKEN")

# ---------- phase 2: resolve canonical categories ----------
# Categories are seeded by the store-service CategorySeedRunner (idempotent,
# fixed slugs). We just resolve slug -> UUID for use in store creation below.
echo ">> phase 2: resolve canonical category slugs"
CAT_SLUGS=(bakery sushi pizza burgers coffee asian dessert vegan pastry greek)
CAT_DISPLAY=(Bakery Sushi Pizza Burgers Coffee Asian Dessert Vegan Pastry Greek)
# Per-store display lists (parallel arrays indexed by category position).
# Human-readable names, no timestamp suffix.
STORE_NAMES=(
  "Sweet Crumbs"
  "Tokyo Roll"
  "Mama Mia Pizzeria"
  "Burger Yard"
  "Brew House"
  "Wok and Roll"
  "Sugar Cloud"
  "Green Plate"
  "Maison Patisserie"
  "Olive Grove"
)
# Macro-type per store. Mostly RESTAURANT with a sprinkle of BAKERY/CAFE/SWEETS/GROCERY
# so type-based filtering has meaningful variation.
STORE_TYPES=(
  BAKERY
  RESTAURANT
  RESTAURANT
  RESTAURANT
  CAFE
  RESTAURANT
  SWEETS
  GROCERY
  SWEETS
  RESTAURANT
)
# Rating distribution — span of 3.8..5.0 so minRating filters are testable.
STORE_RATINGS=(4.2 4.8 4.6 4.0 4.5 4.7 3.9 4.3 5.0 3.8)
# Surprise box titles per category position.
BOX_TITLES=(
  "Morning Bakery Mix"
  "Chef's Sushi Surprise"
  "Pizza Lover's Box"
  "Burger Combo Bundle"
  "Barista's Coffee Pack"
  "Wok Sampler"
  "Sweet Tooth Treasure"
  "Garden Bowl"
  "Pastry Selection"
  "Mediterranean Mezze"
)
# Menu item names per category position.
ITEM_NAMES=(
  "Sourdough Loaf"
  "Salmon Nigiri"
  "Margherita Pizza"
  "Classic Cheeseburger"
  "Flat White"
  "Pad Thai"
  "Chocolate Lava Cake"
  "Buddha Bowl"
  "Almond Croissant"
  "Souvlaki Plate"
)
# Combo titles per category position.
COMBO_TITLES=(
  "Bakery Trio"
  "Sushi Set 12"
  "Pizza & Drink"
  "Burger Combo"
  "Coffee & Dessert"
  "Wok Duo"
  "Dessert Tasting"
  "Vegan Lunch"
  "Pastry Box"
  "Mezze Platter"
)
# Promo titles per category position.
PROMO_TITLES=(
  "Fresh from the oven"
  "Sushi happy hour"
  "Pizza Friday -20%"
  "Burger & fries combo"
  "Free croissant with coffee"
  "Asian lunch deal"
  "Sweet weekend"
  "Vegan first order"
  "Pastry tasting"
  "Greek wine pairing"
)
# Curated Unsplash photo IDs per category (food-themed, public CDN, stable URLs).
STORE_IMG_IDS=(
  photo-1509440159596-0249088772ff   # Bakery
  photo-1579871494447-9811cf80d66c   # Sushi
  photo-1513104890138-7c749659a591   # Pizza
  photo-1568901346375-23c9450c58cd   # Burgers
  photo-1495474472287-4d71bcdd2085   # Coffee
  photo-1455619452474-d2be8b1e70cd   # Asian
  photo-1488477181946-6428a0291777   # Dessert
  photo-1512621776951-a57141f2eefd   # Vegan
  photo-1551024601-bec78aea704b      # Pastry
  photo-1546069901-ba9599a7e63c      # Greek
)
ITEM_IMG_IDS=(
  photo-1555507036-ab1f4038808a      # Bakery
  photo-1617196034796-73dfa7b1fd56   # Sushi
  photo-1604382354936-07c5d9983bd3   # Pizza
  photo-1550547660-d9450f859349      # Burgers
  photo-1509042239860-f550ce710b93   # Coffee
  photo-1569718212165-3a8278d5f624   # Asian
  photo-1551024506-0bccd828d307      # Dessert
  photo-1540420773420-3366772f4999   # Vegan
  photo-1517433670267-08bbd4be890f   # Pastry
  photo-1606755962773-d324e0a13086   # Greek
)
CAT_IDS=()
for slug in "${CAT_SLUGS[@]}"; do
  id=$(curl -fsS "$GATEWAY/categories/$slug" | extract_id)
  if [ -z "$id" ] || [ "$id" = "null" ]; then
    echo "Category slug=$slug not found — CategorySeedRunner may not have run yet."
    exit 1
  fi
  CAT_IDS+=("$id")
done

# ---------- phase 3: 10 stores ----------
echo ">> phase 3: 10 stores (Kyiv)"
STORE_IDS=()
STORE_LATS=()
STORE_LNGS=()
STORE_NAMES_OUT=()
for i in $(seq 0 9); do
  name="${STORE_NAMES[$i]}"
  type="${STORE_TYPES[$i]}"
  rating="${STORE_RATINGS[$i]}"
  cat_id="${CAT_IDS[$i]}"
  lat=$(awk -v b="$KYIV_LAT_BASE" -v i="$i" 'BEGIN { printf "%.5f", b + i*0.012 }')
  lng=$(awk -v b="$KYIV_LNG_BASE" -v i="$i" 'BEGIN { printf "%.5f", b + i*0.018 }')
  img="https://images.unsplash.com/${STORE_IMG_IDS[$i]}?w=800&q=80"
  hero="https://images.unsplash.com/${STORE_IMG_IDS[$i]}?w=1600&q=80"
  body=$(jq -nc \
    --arg name "$name" \
    --arg desc "$name — handcrafted, locally sourced." \
    --arg img  "$img" \
    --arg hero "$hero" \
    --arg type "$type" \
    --arg cat  "$cat_id" \
    --arg addr "Khreshchatyk ${i}, Kyiv" \
    --arg lat  "$lat" \
    --arg lng  "$lng" \
    --argjson rating "$rating" \
    '{ name:$name, description:$desc, imageUrl:$img, heroImageUrl:$hero,
       type:$type, categoryId:$cat, address:$addr,
       lat:($lat|tonumber), lng:($lng|tonumber),
       rating:$rating, opensAt:"08:00:00", closesAt:"22:00:00",
       phone:"+380501234567", website:"https://example.com",
       deliveryFee:{amount:"25.00",currency:"UAH"},
       minOrderAmount:{amount:"100.00",currency:"UAH"}, priceLevel:2 }')
  id=$(curl -fsS -X POST "$GATEWAY/stores" "${ADM[@]}" \
        -H 'Content-Type: application/json' -d "$body" | extract_id)
  STORE_IDS+=("$id")
  STORE_LATS+=("$lat")
  STORE_LNGS+=("$lng")
  STORE_NAMES_OUT+=("$name")
done

# ---------- phase 4: 10 menu sections ----------
echo ">> phase 4: 10 menu sections"
SECTION_IDS=()
for i in $(seq 0 9); do
  store_id="${STORE_IDS[$i]}"
  body=$(jq -nc '{title:"Main menu", sortOrder:0}')
  id=$(curl -fsS -X POST "$GATEWAY/stores/$store_id/menu-sections" "${ADM[@]}" \
        -H 'Content-Type: application/json' -d "$body" | extract_id)
  SECTION_IDS+=("$id")
done

# ---------- phase 5: 10 menu items ----------
echo ">> phase 5: 10 menu items"
MENU_ITEM_IDS=()
for i in $(seq 0 9); do
  store_id="${STORE_IDS[$i]}"
  section_id="${SECTION_IDS[$i]}"
  body=$(jq -nc \
    --arg name "${ITEM_NAMES[$i]}" \
    --arg desc "Signature dish from ${STORE_NAMES[$i]}." \
    --arg img "https://images.unsplash.com/${ITEM_IMG_IDS[$i]}?w=600&q=80" \
    --arg sid "$section_id" \
    '{ name:$name, description:$desc, price:{amount:"120.00",currency:"UAH"}, imageUrl:$img,
       legacyCategory:"main", available:true, sectionId:$sid }')
  id=$(curl -fsS -X POST "$GATEWAY/stores/$store_id/menu-items" "${ADM[@]}" \
        -H 'Content-Type: application/json' -d "$body" | extract_id)
  MENU_ITEM_IDS+=("$id")
done

# ---------- phase 6: 10 promos ----------
echo ">> phase 6: 10 promos"
PROMO_IDS=()
for i in $(seq 0 9); do
  store_id="${STORE_IDS[$i]}"
  body=$(jq -nc \
    --arg sid "$store_id" \
    --arg t   "${PROMO_TITLES[$i]}" \
    --arg d   "Limited-time offer from ${STORE_NAMES[$i]}." \
    '{ storeId:$sid, title:$t, description:$d,
       emoji:"FIRE", bgColor:"#FFEFD5", accentColor:"#FF6B6B",
       active:true, priority:1 }')
  id=$(curl -fsS -X POST "$GATEWAY/promos" "${ADM[@]}" \
        -H 'Content-Type: application/json' -d "$body" | extract_id)
  PROMO_IDS+=("$id")
done

# ---------- phase 7: 10 combos ----------
echo ">> phase 7: 10 combos"
COMBO_IDS=()
for i in $(seq 0 9); do
  store_id="${STORE_IDS[$i]}"
  item_id="${MENU_ITEM_IDS[$i]}"
  body=$(jq -nc \
    --arg t "${COMBO_TITLES[$i]}" \
    --arg img "https://images.unsplash.com/${STORE_IMG_IDS[$i]}?w=600&q=80" \
    --arg mi "$item_id" \
    '{ title:$t, price:{amount:"199.00",currency:"UAH"},
       imageUrl:$img, savings:50.00, menuItemIds:[$mi] }')
  id=$(curl -fsS -X POST "$GATEWAY/stores/$store_id/combos" "${ADM[@]}" \
        -H 'Content-Type: application/json' -d "$body" | extract_id)
  COMBO_IDS+=("$id")
done

# ---------- phase 8: 10 surprise boxes ----------
echo ">> phase 8: 10 surprise boxes"
# Human-readable titles per category, parallel to STORE_NAMES.
BOX_TITLES=(
  "Morning Bakery Mix"      # Bakery
  "Chef's Sushi Surprise"   # Sushi
  "Pizza Lover's Box"       # Pizza
  "Burger Combo Bundle"     # Burgers
  "Barista's Coffee Pack"   # Coffee
  "Wok Sampler"             # Asian
  "Sweet Tooth Treasure"    # Dessert
  "Garden Bowl"             # Vegan
  "Pastry Selection"        # Pastry
  "Mediterranean Mezze"     # Greek
)
BOX_DISPLAY_CATEGORIES=(Bakery Sushi Pizza Burgers Coffee Asian Dessert Vegan Pastry Greek)
BOX_IDS=()
for i in $(seq 0 9); do
  body=$(jq -nc \
    --arg title "${BOX_TITLES[$i]}" \
    --arg desc "Today's pick from ${STORE_NAMES[$i]} — assorted, while stocks last." \
    --arg img "https://images.unsplash.com/${STORE_IMG_IDS[$i]}?w=600&q=80" \
    --arg sid "${STORE_IDS[$i]}" \
    --arg sname "${STORE_NAMES_OUT[$i]}" \
    --arg slat "${STORE_LATS[$i]}" \
    --arg slng "${STORE_LNGS[$i]}" \
    --arg cat "${CAT_DISPLAY[$i]}" \
    '{ title:$title, description:$desc,
       price:{amount:"150.00",currency:"UAH"},
       retailPrice:{amount:"300.00",currency:"UAH"}, imageUrl:$img,
       storeId:$sid, storeName:$sname,
       storeLat:($slat|tonumber), storeLng:($slng|tonumber),
       pickupFrom:"18:00:00", pickupTo:"21:00:00",
       stock:10, deliveryAvailable:true, rating:4.7,
       recommended:true, category:$cat }')
  id=$(curl -fsS -X POST "$GATEWAY/surprise-boxes" "${ADM[@]}" \
        -H 'Content-Type: application/json' -d "$body" | extract_id)
  BOX_IDS+=("$id")
done

# ---------- phase 9: 10 client users ----------
echo ">> phase 9: 10 client users + login"
CLIENT_TOKENS=()
CLIENT_EMAILS=()
for i in $(seq 0 9); do
  email="seed-client-$TS-$i@foodwise.local"
  pwd="ClientP@ss123"
  curl -fsS -X POST "$GATEWAY/auth/register" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg e "$email" --arg p "$pwd" --arg n "Client $i" \
          '{email:$e, password:$p, name:$n}')" >/dev/null
  token=$(curl -fsS -X POST "$GATEWAY/auth/login" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg e "$email" --arg p "$pwd" '{email:$e, password:$p}')" \
    | extract_token)
  CLIENT_TOKENS+=("$token")
  CLIENT_EMAILS+=("$email")
done

# Profile rows are created by the profile-service Kafka consumer reacting to USER_CREATED.
echo ">> waiting 5s for USER_CREATED events to propagate to profile-service"
sleep 5

# ---------- phase 10: 10 addresses ----------
echo ">> phase 10: 10 addresses"
for i in $(seq 0 9); do
  token="${CLIENT_TOKENS[$i]}"
  body=$(jq -nc \
    --arg street "Khreshchatyk $i/$TS" \
    --arg city "Kyiv" --arg state "Kyiv" \
    --arg zip "0100$i" --arg cn "UA" \
    --arg title "Home-$i-$TS" --arg type "HOME" \
    --arg full "Khreshchatyk $i/$TS, Kyiv" \
    '{ street:$street, city:$city, state:$state, postalCode:$zip,
       country:$cn, title:$title, addressType:$type, fullAddress:$full,
       latitude:50.45, longitude:30.52, isDefault:true }')
  curl -fsS -X POST "$GATEWAY/addresses" \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    -d "$body" >/dev/null
done

# ---------- phase 11: 10 store reviews ----------
echo ">> phase 11: 10 store reviews"
for i in $(seq 0 9); do
  token="${CLIENT_TOKENS[$i]}"
  store_id="${STORE_IDS[$i]}"
  rating=$(( (i % 5) + 1 ))
  body=$(jq -nc --argjson r "$rating" --arg c "Seeded review #$i" \
    '{ rating:$r, comment:$c }')
  curl -fsS -X POST "$GATEWAY/stores/$store_id/reviews" \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    -d "$body" >/dev/null
done

# ---------- phase 12: 10 payment methods ----------
echo ">> phase 12: 10 payment methods"
for i in $(seq 0 9); do
  token="${CLIENT_TOKENS[$i]}"
  body=$(jq -nc \
    --arg t "CARD" \
    --arg b "Visa" \
    --arg l "424$i" \
    '{ type:$t, brand:$b, last4:$l,
       expMonth:12, expYear:2030, isDefault:true }')
  curl -fsS -X POST "$GATEWAY/payment-methods" \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    -d "$body" >/dev/null
done

# ---------- phase 13: 10 orders ----------
echo ">> phase 13: 10 orders"
for i in $(seq 0 9); do
  token="${CLIENT_TOKENS[$i]}"
  body=$(jq -nc \
    --arg sid "${STORE_IDS[$i]}" \
    --arg box "${BOX_IDS[$i]}" \
    --arg addr "Khreshchatyk $i/$TS, Kyiv" \
    '{ storeId:$sid,
       items:[{ surpriseBoxId:$box, quantity:1 }],
       paymentType:"CARD", deliveryType:"PICKUP", deliveryAddress:$addr }')
  curl -fsS -X POST "$GATEWAY/orders" \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    -d "$body" >/dev/null
done

# ---------- verification ----------
echo ""
echo "=== seed verification ==="
run_psql foodwise_auth -c "SELECT 'users' AS t, count(*) FROM users;"
run_psql foodwise_stores -c "
  SELECT 'categories'       AS t, count(*) FROM categories
  UNION ALL SELECT 'stores',           count(*) FROM stores
  UNION ALL SELECT 'menu_sections',    count(*) FROM menu_sections
  UNION ALL SELECT 'store_menu_items', count(*) FROM store_menu_items
  UNION ALL SELECT 'store_promos',     count(*) FROM store_promos
  UNION ALL SELECT 'combos',           count(*) FROM combos
  UNION ALL SELECT 'store_reviews',    count(*) FROM store_reviews;"
run_psql foodwise_surprisebox -c \
  "SELECT 'surprise_boxes' AS t, count(*) FROM surprise_boxes;"
run_psql foodwise_profile -c \
  "SELECT 'profiles' AS t, count(*) FROM profiles
   UNION ALL SELECT 'addresses', count(*) FROM addresses;"
run_psql foodwise_orders -c \
  "SELECT 'orders' AS t, count(*) FROM orders
   UNION ALL SELECT 'order_items', count(*) FROM order_items;"
run_psql foodwise_payment -c \
  "SELECT 'payment_methods' AS t, count(*) FROM payment_methods;"
echo "=== done ==="
