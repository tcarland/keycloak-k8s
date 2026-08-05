
all:

clean:

distclean:
	( rm -rf base/realm.json \
	  base/secrets.env \
	  postgres/postgres.env )
