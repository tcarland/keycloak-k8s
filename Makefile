
all:

clean:

distclean:
	( rm -rf base/realm.json \
	  base/secrets.env \
	  overlays/**/*.crt \
	  overlays/**/*.key \
	  postgres/postgres.env )
